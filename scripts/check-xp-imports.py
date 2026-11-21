#!/usr/bin/env python3
"""Will this .exe load on Windows XP? Checks what the loader checks first.

An XP loader refuses a program whose PE header asks for a newer Windows,
and stops with "entry point not found" when the program imports, by name
at load time, a DLL or a function XP does not have. Functions a program
looks up itself with GetProcAddress are not imports and are not checked
(that is how a program uses a newer API only where it exists).

The function list is the Vista-and-later API a Pascal or C program is
likely to reach for; it cannot be complete without XP's own export
tables, so a pass means "nothing known to be missing", not a guarantee.

usage: check-xp-imports.py <file.exe>     (needs objdump; exit 0 = loads)
"""
import re
import shutil
import subprocess
import sys

# DLLs XP does not have at all.
MISSING_DLLS = re.compile(r'^(api-ms-win-.*|ext-ms-win-.*|bcrypt|ncrypt|dwmapi|propsys|ktmw32|'
                          r'mfplat|d3d1[01].*|dxgi|d2d1|dwrite|wevtapi|ucrtbase|vcruntime14.*|'
                          r'msvcp14.*|powrprof_vista)\.dll$', re.I)

# Functions added in Vista or later (kernel32, advapi32, ws2_32, shell32,
# user32, iphlpapi).
MISSING_FUNCS = set("""
GetTickCount64 GetFinalPathNameByHandleA GetFinalPathNameByHandleW
InitializeSRWLock AcquireSRWLockExclusive AcquireSRWLockShared ReleaseSRWLockExclusive
ReleaseSRWLockShared TryAcquireSRWLockExclusive TryAcquireSRWLockShared
InitializeConditionVariable SleepConditionVariableCS SleepConditionVariableSRW
WakeConditionVariable WakeAllConditionVariable
InitOnceExecuteOnce InitOnceBeginInitialize InitOnceComplete InitOnceInitialize
CreateSymbolicLinkA CreateSymbolicLinkW GetFileInformationByHandleEx SetFileInformationByHandle
CancelIoEx CancelSynchronousIo CreateEventExA CreateEventExW CreateMutexExA CreateMutexExW
CreateSemaphoreExA CreateSemaphoreExW CreateWaitableTimerExW
GetLocaleInfoEx LCIDToLocaleName LocaleNameToLCID GetUserDefaultLocaleName
GetSystemDefaultLocaleName CompareStringEx CompareStringOrdinal LCMapStringEx
EnumSystemLocalesEx ResolveLocaleName GetUserPreferredUILanguages GetFileMUIPath
FlsAlloc FlsFree FlsGetValue FlsSetValue
QueryFullProcessImageNameA QueryFullProcessImageNameW GetProductInfo
GetErrorMode SetThreadErrorMode GetThreadErrorMode GetCurrentProcessorNumber
GetCurrentProcessorNumberEx AddDllDirectory RemoveDllDirectory SetDefaultDllDirectories
GetSystemTimePreciseAsFileTime CreateRemoteThreadEx GetThreadId GetProcessIdOfThread
CreateThreadpoolWork SubmitThreadpoolWork CloseThreadpoolWork WaitForThreadpoolWorkCallbacks
TrySubmitThreadpoolCallback CreateThreadpoolTimer SetThreadpoolTimer CloseThreadpoolTimer
RegisterApplicationRestart RegisterApplicationRecoveryCallback
GetDynamicTimeZoneInformation GetTimeZoneInformationForYear
SetFileCompletionNotificationModes GetQueuedCompletionStatusEx RaiseFailFastException
NormalizeString IsNormalizedString IdnToAscii IdnToUnicode GetNamedPipeClientProcessId
QueryThreadCycleTime QueryProcessCycleTime GetLogicalProcessorInformationEx
Wow64DisableWow64FsRedirection Wow64RevertWow64FsRedirection
GetOverlappedResultEx CreateFile2 CopyFile2 GetLocalTimeAsFileTime
K32GetModuleFileNameExW K32EnumProcesses K32GetProcessMemoryInfo K32EnumProcessModules
RegGetValueA RegGetValueW RegDeleteKeyExA RegDeleteKeyExW RegCopyTreeA RegCopyTreeW
RegDeleteTreeA RegDeleteTreeW RegSetKeyValueA RegSetKeyValueW RegLoadMUIStringW
EventRegister EventWrite EventUnregister
inet_pton inet_ntop InetPtonA InetPtonW InetNtopA InetNtopW WSAPoll GetAddrInfoExW
FreeAddrInfoExW WSAConnectByNameW if_nametoindex if_indextoname
SHGetKnownFolderPath SHCreateItemFromParsingName SetProcessDPIAware ChangeWindowMessageFilter
GetDpiForWindow GetDpiForSystem SetProcessDpiAwarenessContext
""".split())


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1])
        return 2
    exe = sys.argv[1]
    if not shutil.which('objdump'):
        print('  skip: check-xp-imports needs objdump')
        return 0
    out = subprocess.run(['objdump', '-p', exe], capture_output=True, text=True).stdout
    problems = []
    for field in ('MajorOSystemVersion', 'MajorSubsystemVersion'):
        m = re.search(r'^%s\s+(\d+)' % field, out, re.M)
        minor = re.search(r'^%s\s+(\d+)' % field.replace('Major', 'Minor'), out, re.M)
        if not m:
            problems.append('no %s in the PE header (is this a PE file?)' % field)
            continue
        ver = (int(m.group(1)), int(minor.group(1)) if minor else 0)
        if ver > (5, 1):
            problems.append('%s is %d.%d; XP is 5.1 and refuses anything newer' % (field, ver[0], ver[1]))
    dll, imports = None, []
    in_imports = False
    for line in out.splitlines():
        m = re.match(r'\s*DLL Name: (\S+)', line)
        if m:
            dll, in_imports = m.group(1), True
            if MISSING_DLLS.match(dll):
                problems.append('imports %s, which XP does not have' % dll)
            continue
        if in_imports:
            m = re.match(r'\s+[0-9a-f]+\s+\d+\s+([A-Za-z_][A-Za-z0-9_@]*)\s*$', line)
            if m:
                imports.append((dll, m.group(1)))
            elif line.strip() == '' or line.startswith('The '):
                in_imports = line.strip() == '' and in_imports
    if not imports:
        problems.append('found no imported functions; objdump output not understood')
    for d, fn in imports:
        if fn in MISSING_FUNCS:
            problems.append('imports %s from %s, which XP does not have (look it up with GetProcAddress)' % (fn, d))
    if problems:
        for p in problems:
            print('FAIL: %s: %s' % (exe, p))
        return 1
    print('xp imports: OK (%d functions from %d DLLs, none known to be missing on XP)'
          % (len(imports), len({d for d, _ in imports})))
    return 0


if __name__ == '__main__':
    sys.exit(main())
