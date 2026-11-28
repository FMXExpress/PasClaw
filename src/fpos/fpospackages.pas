(*
  The FPC package units the FreePascalOS build of PasClaw uses.

  On the other targets these come precompiled with the FPC install. For
  FreePascalOS there is no such install, so `make fpos` compiles this
  unit first, from FPC's package sources (and fcl-process from
  FreePascalOS's port of it), with the packages' own settings -- not
  PasClaw's -MDelphi -Sh, which some of them do not compile under --
  into build/fpos/pkg; PasClaw is then compiled against those units.
  Compiling this unit compiles every unit it names and what they use.
  Nothing calls into it. A unit PasClaw needs that is missing here shows
  up as "Can't find unit" when PasClaw is compiled: add it.

  PasClaw's own code, MIT like the rest of it.
*)
unit fpospackages;

interface

uses
  { fcl-base, fcl-json, hash, paszlib }
  base64, fpjson, jsonparser, jsonscanner, sha1, md5, crc, zipper, zstream,
  { fcl-process (the FreePascalOS port) }
  process, pipes,
  { fcl-db and sqlite: libsqlite3 is loaded at run time, and is not there
    on FreePascalOS, so these only report that }
  db, sqldb, sqlite3conn, sqlite3dyn,
  { regexpr, rtl-generics }
  regexpr, generics.collections, generics.defaults,
  { Lazarus lazutils: Masks for fs_grep's include filter }
  masks;

implementation

end.
