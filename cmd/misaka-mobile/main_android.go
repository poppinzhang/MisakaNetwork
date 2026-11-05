package main

/*
#include <stdlib.h>
*/
import "C"

import "github.com/MisakaNetwork/MisakaNetwork/internal/mobile"
import "unsafe"

//export MisakaHandle
func MisakaHandle(request *C.char, requestLength C.int, root *C.char, rootLength C.int) *C.char {
	return C.CString(string(mobile.Handle(C.GoBytes(unsafe.Pointer(request), requestLength), C.GoStringN(root, rootLength))))
}

func main() {}
