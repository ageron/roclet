#include <stddef.h>
#include <limits.h>
void* roclet_md_alloc(size_t size);
void* roclet_md_realloc(void* ptr, size_t size);
void roclet_md_free(void* ptr);
int roclet_md_block(void* user, unsigned type, unsigned start, unsigned end, unsigned fenced);
#define malloc roclet_md_alloc
#define realloc roclet_md_realloc
#define free roclet_md_free
#ifdef __wasm__
static void md_swap(unsigned char* a, unsigned char* b, size_t size) { while(size--) { unsigned char x = *a; *a++ = *b; *b++ = x; } }
static void md_sift(unsigned char* p, size_t n, size_t i, size_t z, int (*cmp)(const void*, const void*)) {
    while(i < n / 2) { size_t c = i*2+1; if(c+1 < n && cmp(p+c*z, p+(c+1)*z) < 0) c++; if(cmp(p+i*z,p+c*z) >= 0) break; md_swap(p+i*z,p+c*z,z); i=c; }
}
static void qsort(void* base, size_t n, size_t z, int (*cmp)(const void*,const void*)) {
    unsigned char* p = base; size_t i = n/2; while(i) md_sift(p,n,--i,z,cmp); while(n > 1) { md_swap(p,p+(--n)*z,z); md_sift(p,n,0,z,cmp); }
}
static void* bsearch(const void* key, const void* base, size_t n, size_t z, int (*cmp)(const void*,const void*)) {
    const unsigned char* p = base; while(n) { size_t mid=n/2; const void* item=p+mid*z; int c=cmp(key,item); if(!c) return (void*)item; if(c>0) { p += (mid+1)*z; n -= mid+1; } else n=mid; } return NULL;
}
void* memcpy(void*, const void*, size_t);
void* memmove(void*, const void*, size_t);
void* memset(void*, int, size_t);
int memcmp(const void*, const void*, size_t);
static const char* strchr(const char* s, int c) { while (*s && *s != c) s++; return *s == c ? s : NULL; }
#else
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#endif
