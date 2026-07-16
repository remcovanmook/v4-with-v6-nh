@echo off
rem Build v4gwd.exe for Windows.
rem
rem Run from a Visual Studio "Developer Command Prompt":
rem   - native on Windows-on-ARM:      "ARM64 Native Tools Command Prompt"
rem   - cross from an x64 dev box:      run  vcvarsall.bat x64_arm64  first
rem
rem clang-cl works too (same flags); or drive the arch with VsDevCmd:
rem   VsDevCmd.bat -arch=arm64 -host_arch=arm64   (native)
rem   VsDevCmd.bat -arch=arm64 -host_arch=amd64   (cross)

setlocal
cl /nologo /W4 /O2 /D_CRT_SECURE_NO_WARNINGS v4gwd.c /Fe:v4gwd.exe ^
   /link iphlpapi.lib ws2_32.lib advapi32.lib
endlocal
