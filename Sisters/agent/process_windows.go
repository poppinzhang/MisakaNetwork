package agent

import (
	"errors"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Start suspended: assigning an already running process to a Job Object
// would allow it to create an uncontained child before assignment. Neither
// breakaway flag is enabled, and the job handle is never inherited.
func startIsolatedProcess(cmd *exec.Cmd) (func(), error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	var mu sync.Mutex
	closeJob := func() {
		mu.Lock()
		defer mu.Unlock()
		if job != 0 {
			windows.CloseHandle(job)
			job = 0
		}
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_SUSPENDED}
	cmd.Cancel = func() error {
		mu.Lock()
		defer mu.Unlock()
		if job == 0 {
			return os.ErrProcessDone
		}
		return windows.TerminateJobObject(job, 1)
	}
	// Serialize cancellation with assignment/resume. Terminating an empty job
	// before assignment must never let the suspended process subsequently run.
	mu.Lock()
	err = cmd.Start()
	if err == nil {
		err = attachAndResume(job, uint32(cmd.Process.Pid))
		if err != nil {
			// The process is still suspended or already assigned to the job.
			// Kill both forms before releasing the cancellation lock.
			_ = windows.TerminateJobObject(job, 1)
			_ = cmd.Process.Kill()
		}
	}
	mu.Unlock()
	if err != nil {
		if cmd.Process != nil {
			_ = cmd.Wait()
		}
		closeJob()
		return nil, err
	}
	return closeJob, nil
}

func attachAndResume(job windows.Handle, pid uint32) error {
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(process)
	if err := windows.AssignProcessToJobObject(job, process); err != nil {
		return err
	}
	// Go's exec API closes the initial thread handle. The suspended process
	// has not executed user code, so its only thread is the primary thread.
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	for err = windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID != pid {
			continue
		}
		thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
		if err != nil {
			return err
		}
		defer windows.CloseHandle(thread)
		previous, err := windows.ResumeThread(thread)
		if err != nil {
			return err
		}
		if previous != 1 {
			return errors.New("unexpected runtime suspension state")
		}
		return nil
	}
	return errors.New("cannot locate suspended runtime thread")
}

func runtimeExecutable(info os.FileInfo) bool {
	// Windows regular files do not carry Unix executable permission bits.
	return info.Mode().IsRegular()
}
