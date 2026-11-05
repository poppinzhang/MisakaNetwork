#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "_cgo_export.h"

JNIEXPORT jbyteArray JNICALL
Java_com_misakanetwork_last_1order_EmbeddedBridge_nativeHandle(
    JNIEnv *env, jobject self, jbyteArray request, jbyteArray root) {
    (void)self;
    if (request == NULL || root == NULL) return NULL;
    jsize request_len = (*env)->GetArrayLength(env, request);
    jsize root_len = (*env)->GetArrayLength(env, root);
    if (request_len <= 0 || request_len > 1048576 || root_len <= 0 || root_len > 4096) return NULL;
    jbyte *request_bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (request_bytes == NULL) return NULL;
    jbyte *root_bytes = (*env)->GetByteArrayElements(env, root, NULL);
    if (root_bytes == NULL) {
        (*env)->ReleaseByteArrayElements(env, request, request_bytes, JNI_ABORT);
        return NULL;
    }
    char *response = MisakaHandle((char *)request_bytes, request_len, (char *)root_bytes, root_len);
    (*env)->ReleaseByteArrayElements(env, request, request_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, root, root_bytes, JNI_ABORT);
    if (response == NULL) return NULL;
    size_t response_len = strlen(response);
    jbyteArray result = (*env)->NewByteArray(env, (jsize)response_len);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize)response_len, (const jbyte *)response);
    free(response);
    return result;
}
