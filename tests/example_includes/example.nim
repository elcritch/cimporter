when defined(__unix__):
  let unix*: cint = 1
else:
  let unix*: cint = 0
proc example*(): cint
## !!!Ignored construct:  when defined ( __unix__ ) : let unix * : cint = 1 else : let unix * : cint = 0 proc example * ( ) : cint
## Error: expected ';'!!!
