#!/usr/bin/env python3
"""Checks a pasclaw built by `make fpos` is a FreePascalOS program.

    check-fpos-binary.py <pasclaw>

FreePascalOS loads position independent x86-64 ELF programs and binds
their symbols against the shared libraries they name (DT_NEEDED, found
through DT_HASH). This reads the ELF file itself -- no readelf needed --
and checks:

  - ELF64, little endian, x86-64, ET_DYN (PIE), with an entry point;
  - no program interpreter (FreePascalOS's kernel loads programs itself);
  - DT_HASH present (the loader looks symbols up through it);
  - the libraries it needs are the system's: libsystem and libhttp among
    them, and nothing from a Linux system (libc, libssl, libdl ...);
  - the text it carries says what the FreePascalOS build leaves out
    (tui's "not available on FreePascalOS"), names its platform for
    `pasclaw version`, has Indy on its FreePascalOS socket stack
    (src/fpos/indy) and the web UI the gateway serves (the resource of
    PasClaw.Gateway.WebUI), and none of OpenSSL's names: Indy's TLS is
    left out there.

Exits 0 and prints "fpos binary: OK" when all hold.
"""
import struct
import sys

PT_INTERP, PT_DYNAMIC = 3, 2
DT_NULL, DT_NEEDED, DT_HASH, DT_STRTAB = 0, 1, 4, 5


def fail(msg):
    print('FAIL: check-fpos-binary: ' + msg)
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    data = open(sys.argv[1], 'rb').read()
    if data[:4] != b'\x7fELF':
        fail('not an ELF file')
    if data[4] != 2 or data[5] != 1:
        fail('not ELF64 little endian')
    e_type, e_machine = struct.unpack_from('<HH', data, 16)
    e_entry, e_phoff = struct.unpack_from('<QQ', data, 24)
    e_phentsize, e_phnum = struct.unpack_from('<HH', data, 54)
    if e_machine != 62:
        fail('not x86-64 (e_machine %d)' % e_machine)
    if e_type != 3:
        fail('not position independent (e_type %d, want ET_DYN)' % e_type)
    if e_entry == 0:
        fail('no entry point')
    segments = []
    for i in range(e_phnum):
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from(
            '<IIQQQQ', data, e_phoff + i * e_phentsize)
        segments.append((p_type, p_offset, p_vaddr, p_filesz))
    if any(s[0] == PT_INTERP for s in segments):
        fail('has a program interpreter (PT_INTERP); FreePascalOS loads programs itself')
    dynamic = [s for s in segments if s[0] == PT_DYNAMIC]
    if not dynamic:
        fail('no dynamic section')
    _t, off, _va, size = dynamic[0]
    entries = []
    for i in range(0, size, 16):
        tag, val = struct.unpack_from('<qQ', data, off + i)
        if tag == DT_NULL:
            break
        entries.append((tag, val))
    tags = dict((t, v) for t, v in entries if t != DT_NEEDED)
    if DT_HASH not in tags:
        fail('no DT_HASH (the FreePascalOS loader looks symbols up through it)')

    def vaddr_to_offset(vaddr):
        for p_type, p_offset, p_vaddr, p_filesz in segments:
            if p_type == 1 and p_vaddr <= vaddr < p_vaddr + p_filesz:
                return p_offset + (vaddr - p_vaddr)
        fail('address %#x is in no loaded segment' % vaddr)
    strtab = vaddr_to_offset(tags[DT_STRTAB])

    def string_at(index):
        end = data.index(b'\0', strtab + index)
        return data[strtab + index:end].decode()
    needed = [string_at(v) for t, v in entries if t == DT_NEEDED]
    for lib in ('libsystem.so', 'libhttp.so'):
        if lib not in needed:
            fail('does not need %s (needs: %s)' % (lib, ', '.join(needed)))
    foreign = [n for n in needed if n.split('.so')[0] in ('libc', 'libssl', 'libcrypto', 'libdl', 'libpthread', 'libm', 'libsqlite3')]
    if foreign:
        fail('needs libraries FreePascalOS does not have: ' + ', '.join(foreign))
    for text, what in ((b'not available on FreePascalOS', 'what it leaves out'),
                       (b'FreePascalOS', 'its platform'),
                       (b'TIdStackFreePascalOS', "Indy's FreePascalOS socket stack"),
                       (b'TIdHTTPServer', "the gateway's HTTP server"),
                       (b'<title>PasClaw</title>', 'the web UI resource')):
        if text not in data:
            fail('does not carry %r (%s)' % (text.decode(), what))
    for text in (b'SSL_CTX_new', b'TIdSSLIOHandlerSocketOpenSSL'):
        if text in data:
            fail('carries %r: OpenSSL was linked' % text.decode())
    print('fpos binary: OK (%d bytes; needs %s)' % (len(data), ', '.join(needed)))


if __name__ == '__main__':
    main()
