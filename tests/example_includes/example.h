#ifndef __EXAMPLR_H__
#define __EXAMPLR_H__

#ifdef __unix__
const int unix = 1;
#else
const int unix = 0;
#include <stdio.h>
#endif
#include <stdio.h>

int example();

#endif // __EXAMPLR_H__