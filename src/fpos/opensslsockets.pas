(*
  opensslsockets for the FreePascalOS build of PasClaw: empty.

  On the other FPC targets this unit registers OpenSSL as fphttpclient's
  TLS handler. FreePascalOS has no OpenSSL; its libhttp does TLS itself
  through libtls, and src/fpos/fphttpclient.pas goes through libhttp.
  The units that name opensslsockets build unchanged with this one.
  Only `make fpos` puts src/fpos on the unit path.

  PasClaw's own code, MIT like the rest of it.
*)
unit opensslsockets;

interface

implementation

end.
