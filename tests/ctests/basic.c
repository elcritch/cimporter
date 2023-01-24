#ifdef __unix__
const int unix = 1;
#else
const int unix = 0;
#include <stdio.h>
#endif
#include <stdio.h>

int main() {
   // printf() displays the string inside quotation
   printf("Hello, World!");
   return 0;
}