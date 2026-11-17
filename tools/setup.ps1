# One-click setup for win2000-recomp: Windows 2000's own userland, statically
# recompiled, with its explorer in a window on this PC. Run it by
# double-clicking Setup.cmd in the repo folder; the README's "Building by
# hand" is the same thing command for command.
#
# It takes the I386 folder from your Windows 2000 CD image, expands the files
# it needs, rebases them out of the host's way, lifts and builds explorer,
# rundll32, cmd and the accessories, seeds explorer's registry box and private
# profile, and leaves "Windows 2000 (recomp).cmd" here. Each step is skipped
# when its output already exists (-Force redoes them). Everything it does goes
# to setup.log. -Yes installs what is missing without asking; -Iso is your
# Windows 2000 Professional SP4 CD image (an .iso, or a folder or drive
# holding I386), asked for when not given.
# -Linux also lifts the Linux sets and fills work\linux, the folder ./setup.sh
# builds on a Linux machine (copy it there; README "Getting Started").
# RECOMP_LAUNCHER=1 skips the "Press Enter" at the end.
param([switch]$Force, [switch]$Yes, [switch]$Linux, [string]$Iso = "")

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
# The toolkit: PCRECOMP, else ../pcrecomp (cloned when missing).
$Parent = Split-Path -Parent $Root
$Toolkit = if ($env:PCRECOMP) { $env:PCRECOMP } else { Join-Path $Parent 'pcrecomp' }
$T = Join-Path $Toolkit 'tools'
$Log = Join-Path $Root 'setup.log'
Set-Location $Root
$Steps = 9 + $(if ($Linux) { 2 } else { 0 })
function Log($t) { try { Add-Content -Path $Log -Value $t -Encoding UTF8 -ErrorAction Stop } catch {} }
Log "==== setup $(Get-Date -Format s)"

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c; Log $t }
function Pause-End { if (-not $env:RECOMP_LAUNCHER) { Read-Host "Press Enter to close" | Out-Null } }
# cmd.exe, which the lift scripts build through, splits a path at '&' and at spaces.
if ($Root -match '[& ]') {
  Say "This folder's path has a space or an '&' in it, which the build cannot handle:" 'Red'
  Say "  $Root" 'Red'
  Say "Move the folder somewhere else (for example C:\win2000-recomp) and run Setup.cmd from there." 'Yellow'
  Pause-End; exit 1
}
function Step($n, $t) { Write-Host ""; Say "[$n/$Steps] $t" 'Cyan' }
function Fail($t) {
  Say "" ; Say "Setup stopped: $t" 'Red'
  Say "The details are in $Log. Fix that and run Setup.cmd again; finished steps are skipped." 'Yellow'
  Pause-End; exit 1
}
function Ask($q) { if ($Yes) { Say "$q yes"; return $true }; $a = Read-Host "$q [Y/n]"; return -not ($a -match '^[nN]') }   # Enter = yes
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
# Run a program with its output in the log. Windows PowerShell turns a native
# program's stderr into errors, so 'Stop' is off while it runs.
function Exec([string[]]$cmd) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $rest = @($cmd | Select-Object -Skip 1)   # @(): a one-element slice would splat as characters
  & $cmd[0] @rest 2>&1 | ForEach-Object { Log "$_" }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  return $code
}
function Run($what, [string[]]$cmd) {
  Say "  $what..."
  $code = Exec $cmd
  if ($code -ne 0) { Fail "$what failed (exit code $code)." }
}
function Done($p) { return (-not $Force) -and (Test-Path -LiteralPath $p) }

Clear-Host
Say "Windows 2000 - static recompilation setup" 'White'
Say "You need your own Windows 2000 Professional SP4 CD image and about 25 GB free."
Say "Lifting and building take about 2 hours, once$(if ($Linux) { ', and the Linux sets about 30 minutes more' })."

# ---------------------------------------------------------------- tools
Step 1 "Checking the tools the pipeline needs"
# The scripts run "py -3" (the Python launcher, which python.org's and winget's Python install).
function Py-Ok {
  if (-not (Get-Command py -ErrorAction SilentlyContinue)) { return $false }
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $v = (& py -3 --version 2>&1 | Out-String).Trim()
  $ErrorActionPreference = $old
  return ($v -match '^Python 3\.(\d+)' -and [int]$Matches[1] -ge 10)
}
if (-not (Py-Ok)) {
  Say "  Python 3.10 or newer (with the py launcher) is not installed."
  if (-not (Ask "  Install Python 3.12 now (winget, for your user only, about 30 MB)?")) { Fail "Python 3 is required." }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget is missing. Install 'App Installer' from the Microsoft Store, or install Python from python.org yourself."
  }
  Exec @('winget', 'install', '-e', '--id', 'Python.Python.3.12', '--scope', 'user', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
  Refresh-Path
  if (-not (Py-Ok)) { Fail "Python installed, but Windows has not picked it up yet: close this window and run Setup.cmd again." }
}
Say "  Python: py -3"
if ((Exec @('py', '-3', '-c', 'import pefile, capstone')) -ne 0) {
  Say "  The Python packages pefile and capstone are missing (about 15 MB)."
  if (-not (Ask "  Install them now (pip, for your user only)?")) { Fail "pefile and capstone are required." }
  Run "Installing pefile and capstone" @('py', '-3', '-m', 'pip', 'install', '--user', 'pefile', 'capstone')
}

# Git for Windows: git for pcrecomp, and its bash for the lift scripts (tools\*.sh).
# Not "bash" from PATH: that can be WSL's.
function Find-GitBash {
  $g = Get-Command git -ErrorAction SilentlyContinue
  $cands = @()
  if ($g) { $cands += (Join-Path (Split-Path -Parent (Split-Path -Parent $g.Source)) 'bin\bash.exe') }
  $cands += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  return $null
}
$Bash = Find-GitBash
if (-not $Bash) {
  Say "  Git for Windows (git, and the bash the lift scripts run in) is not installed."
  if (-not (Ask "  Install Git for Windows now (winget, about 300 MB)?")) { Fail "Git for Windows is required." }
  Exec @('winget', 'install', '-e', '--id', 'Git.Git', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
  Refresh-Path
  $Bash = Find-GitBash
  if (-not $Bash) { Fail "Git installed, but Windows has not picked it up yet: close this window and run Setup.cmd again." }
}
Say "  bash: $Bash"

# 7-Zip: the CD image and the CD's compressed files (X.DL_).
function Find-7z {
  foreach ($c in @((Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'))) { if (Test-Path $c) { return $c } }
  $g = Get-Command 7z -ErrorAction SilentlyContinue
  if ($g) { return $g.Source }
  return $null
}
$SevenZip = Find-7z
if (-not $SevenZip) {
  Say "  7-Zip is not installed."
  if (-not (Ask "  Install 7-Zip now (winget, about 2 MB)?")) { Fail "7-Zip is required." }
  Exec @('winget', 'install', '-e', '--id', '7zip.7zip', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
  $SevenZip = Find-7z
  if (-not $SevenZip) { Fail "7-Zip installed, but it is not where it should be: run Setup.cmd again." }
}
Say "  7-Zip: $SevenZip"
# the lift scripts call "7z" and "py": both on their PATH
$env:Path = (Split-Path -Parent $SevenZip) + ';' + $env:Path

if (-not (Test-Path (Join-Path $T 'lift\drive32.py'))) {
  Say "  The pcrecomp toolkit is not beside this folder ($Toolkit)."
  if (-not (Ask "  Download it now (git, about 30 MB)?")) { Fail "pcrecomp is required at $Toolkit." }
  Run "Cloning pcrecomp" @('git', 'clone', '--depth', '1', 'https://github.com/sp00nznet/pcrecomp', $Toolkit)
}
# Windows 2000's win32k layer and the Linux backend: pcrecomp from after the w2k-linux merge.
$tkOk = { (Test-Path (Join-Path $Toolkit 'runtime\native32\w32kuser.c')) -and (Test-Path (Join-Path $Toolkit 'runtime\native32\ntposix.c')) -and
          (Test-Path (Join-Path $Toolkit 'runtime\native32\w32klayout.c')) }
if (-not (& $tkOk) -and (Test-Path (Join-Path $Toolkit '.git'))) {
  Say "  Your pcrecomp is older than this build needs."
  if (Ask "  Update it now (git pull)?") { Run "Updating pcrecomp" @('git', '-C', $Toolkit, 'pull', '--ff-only') }
}
if (-not (& $tkOk)) { Fail "your pcrecomp at $Toolkit is too old for this build. Update it: git -C `"$Toolkit`" pull" }
$env:PCRECOMP = $Toolkit -replace '\\', '/'
Say "  pcrecomp: $Toolkit"

# The compiler. build.cmd finds Visual Studio itself; this only checks that it
# is there, with CMake and Ninja.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = if (Test-Path $vswhere) { (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) } else { $null }
if (-not $vs) {
  Say "  Visual Studio 2022 with the C++ tools is not installed."
  if (-not (Ask "  Install the Visual Studio 2022 Build Tools with the C++ workload now (winget, about 3 GB, asks for admin)?")) {
    Fail "Visual Studio 2022 (or its Build Tools) with 'Desktop development with C++' is needed. Install it, then run Setup.cmd again."
  }
  Exec @('winget', 'install', '-e', '--id', 'Microsoft.VisualStudio.2022.BuildTools', '--accept-package-agreements', '--accept-source-agreements',
         '--override', '--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended') | Out-Null
  $vs = if (Test-Path $vswhere) { (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) } else { $null }
  if (-not $vs) { Fail "the Visual Studio Build Tools did not install. Install them with 'Desktop development with C++', then run Setup.cmd again." }
}
Say "  Visual Studio: $vs"
foreach ($tool in @(@('cmake', 'Kitware.CMake', '30 MB'), @('ninja', 'Ninja-build.Ninja', '1 MB'))) {
  if (Get-Command $tool[0] -ErrorAction SilentlyContinue) { continue }
  Say "  $($tool[0]) is not installed."
  if (-not (Ask "  Install $($tool[0]) now (winget, about $($tool[2]))?")) { Fail "$($tool[0]) is required." }
  Exec @('winget', 'install', '-e', '--id', $tool[1], '--accept-package-agreements', '--accept-source-agreements') | Out-Null
  Refresh-Path
  $env:Path = (Split-Path -Parent $SevenZip) + ';' + $env:Path
  if (-not (Get-Command $tool[0] -ErrorAction SilentlyContinue)) { Fail "$($tool[0]) installed, but Windows has not picked it up yet: close this window and run Setup.cmd again." }
}

# A tools\*.sh script in Git's bash, from the repo root, output in the log.
function Sh($what, $script) { Run $what @($Bash, '-c', "cd '$($Root -replace '\\', '/')' && $script") }

# ---------------------------------------------------------------- the CD
Step 2 "Copying I386 from your Windows 2000 CD into work\iso"
$I386 = 'work\iso\I386'
function Is-Cd([string]$p) {
  if (-not $p) { return $false }
  if (Test-Path -LiteralPath $p -PathType Container) { return (Test-Path (Join-Path $p 'I386\NTDLL.DLL')) }
  return ((Test-Path -LiteralPath $p -PathType Leaf) -and $p -match '\.iso$')
}
if ((Done "$I386\HIVEDEF.INF") -and (Test-Path "$I386\NTDLL.DLL")) {
  Say "  Already in work\iso (skipping)."
} else {
  $Iso = $Iso.Trim('"', ' ')
  if (-not (Is-Cd $Iso)) {   # an image next to Setup.cmd
    $Iso = @(Get-ChildItem -Path $Root -Filter *.iso -File -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName })[0]
    if ($Iso) { Say "  Found $Iso" }
  }
  if (-not (Is-Cd $Iso) -and $Yes) { Fail "no Windows 2000 CD image given. Give it with -Iso (an .iso, or a folder or drive holding I386)." }
  while (-not (Is-Cd $Iso)) {
    $Iso = (Read-Host "  Paste the path of your Windows 2000 CD image (an .iso file, or a drive or folder holding I386)").Trim('"', ' ')
    if (-not (Is-Cd $Iso)) { Say "  That is not an .iso file or a folder with I386\NTDLL.DLL in it." 'Yellow' }
  }
  if (Test-Path -LiteralPath $Iso -PathType Container) {
    Say "  Copying $Iso\I386 (about 300 MB)..."
    $code = Exec @('robocopy', (Join-Path $Iso 'I386'), (Join-Path $Root $I386), '/E', '/NFL', '/NDL', '/NJH', '/NP')
    if ($code -ge 8) { Fail "copying I386 failed (robocopy exit code $code)." }
  } else {
    Run "Extracting I386 (about 300 MB)" @($SevenZip, 'x', '-y', '-owork\iso', $Iso, 'I386\*')
  }
}
# Windows 2000 Professional SP4 (5.00.2195, service pack 4): the seeds, the win32k service names
# and the hosts' CSD version are that build's.
$ver = (& py -3 -c "import pefile;v=pefile.PE(r'$I386\NTDLL.DLL').VS_FIXEDFILEINFO[0];print('%d.%d.%d.%d'%(v.FileVersionMS>>16,v.FileVersionMS&0xffff,v.FileVersionLS>>16,v.FileVersionLS&0xffff))" 2>$null)
if (-not $ver) { Fail "work\iso\I386\NTDLL.DLL is not readable: delete work\iso and run Setup.cmd again." }
if (-not ($ver -match '^5\.0\.2195\.(\d+)$')) { Fail "this is not Windows 2000 (5.00.2195): its ntdll is $ver. Delete work\iso and give a Windows 2000 SP4 CD." }
if ([int]$Matches[1] -lt 6600) { Say "  ntdll $ver is not Service Pack 4's (5.0.2195.6685): the build may not work. An SP4 CD is what it was made on." 'Yellow' }
else { Say "  Windows 2000 $ver (SP4)" }

# ---------------------------------------------------------------- expand
Step 3 "Expanding the files it needs into work\sys"
$SysFiles = @('ntdll.dll', 'kernel32.dll', 'msvcrt.dll', 'user32.dll', 'gdi32.dll', 'advapi32.dll', 'comctl32.dll', 'shlwapi.dll',
  'shell32.dll', 'browseui.dll', 'shdocvw.dll', 'ole32.dll', 'oleaut32.dll', 'rpcrt4.dll', 'actxprxy.dll', 'desk.cpl', 'clbcatq.dll',
  'mydocs.dll', 'explorer.exe', 'cmd.exe', 'find.exe', 'more.com', 'ulib.dll', 'winmine.exe', 'notepad.exe', 'calc.exe', 'clipbrd.exe',
  'packager.exe', 'sol.exe', 'freecell.exe', 'mspaint.exe', 'wordpad.exe', 'cards.dll', 'mfc42u.dll', 'riched20.dll',
  'c_1252.nls', 'c_437.nls', 'l_intl.nls', 'unicode.nls', 'locale.nls', 'ctype.nls', 'sortkey.nls', 'sorttbls.nls')
$Fonts = @('sserife.fon', 'vgasys.fon', 'lucon.ttf', 'tahoma.ttf', 'marlett.ttf')
# A file from the CD: X.DL_ (a cabinet) through 7-Zip, or X.DLL as it is.
function Expand-Cd($name, $dir) {
  $u = Join-Path $I386 $name
  if (Test-Path $u) { Copy-Item $u (Join-Path $dir $name); return }
  $c = Join-Path $I386 ($name.Substring(0, $name.Length - 1) + '_')
  if (-not (Test-Path $c)) { Fail "$name is not on this CD ($I386)." }
  $code = Exec @($SevenZip, 'e', '-y', "-o$dir", $c)
  if ($code -ne 0 -or -not (Test-Path (Join-Path $dir $name))) { Fail "expanding $c failed." }
}
if ((Done 'work\sys\sortkey_00000409.nls') -and (Done 'work\fonts\marlett.ttf') -and (Done 'work\names\win32k_2000sp4.txt')) {
  Say "  Already done (skipping)."
} else {
  New-Item -ItemType Directory -Force work\sys, work\fonts, work\names | Out-Null
  foreach ($f in $SysFiles) { if ($Force -or -not (Test-Path "work\sys\$f")) { Expand-Cd $f 'work\sys' } }
  foreach ($f in $Fonts) { if ($Force -or -not (Test-Path "work\fonts\$f")) { Expand-Cd $f 'work\fonts' } }
  # csrss's per-locale sort table: sortkey.nls with its first WORD 1 ("built"), as src\nthost.c makes it
  $b = [IO.File]::ReadAllBytes((Join-Path $Root 'work\sys\sortkey.nls')); $b[0] = 1; $b[1] = 0
  [IO.File]::WriteAllBytes((Join-Path $Root 'work\sys\sortkey_00000409.nls'), $b)
  Say "  $($SysFiles.Count) files in work\sys, $($Fonts.Count) fonts in work\fonts"
  # win32k's service names for Windows 2000 SP4 (j00ru's public tables; the numbers are the guest's own)
  if ($Force -or -not (Test-Path 'work\names\win32k-per-system.json')) {
    Say "  Downloading win32k's service names (github.com/j00ru/windows-syscalls, 1 MB)..."
    try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/j00ru/windows-syscalls/master/x86/json/win32k-per-system.json' -OutFile 'work\names\win32k-per-system.json' }
    catch { Fail "downloading the win32k names failed: $($_.Exception.Message)" }
  }
  $names = & py -3 tools\w32k_names.py 'Windows 2000' SP4
  if ($LASTEXITCODE -ne 0 -or -not $names) { Fail "tools\w32k_names.py failed." }
  Set-Content -Path 'work\names\win32k_2000sp4.txt' -Value $names -Encoding ASCII
}

# ---------------------------------------------------------------- rebase
Step 4 "Rebasing the system DLLs out of the host's way (work\rebased*)"
if ((Done 'work\rebased-shell\explorer.exe') -and (Test-Path 'work\rebased-gui\wordpad.exe') -and (Test-Path 'work\rebased-util\more.com') -and (Test-Path 'work\rebased\cmd.exe')) {
  Say "  Already done (skipping)."
} else {
  $rb = Join-Path $T 'pe\rebase.py'
  $base = @('ntdll.dll=0x20000000', 'kernel32.dll=0x20100000', 'msvcrt.dll=0x20200000')
  $ug = @('user32.dll=0x20300000', 'gdi32.dll=0x20400000')
  # stage 2: cmd on its own kernel32, ntdll, msvcrt
  Run "work\rebased (cmd)" (@('py', '-3', $rb, 'work\sys', 'work\rebased', 'cmd.exe') + $base + @('--json', 'work\rebased\layout.json'))
  # cmd's utilities on ulib
  Run "work\rebased-util (find, more)" (@('py', '-3', $rb, 'work\sys', 'work\rebased-util', 'ulib.dll=0x20300000') + $base)
  foreach ($e in 'find.exe', 'more.com') { Run "  $e" @('py', '-3', $rb, 'work\sys', 'work\rebased-util', $e) }
  # the accessories on their own user32 and gdi32 (each exe by itself: they share 0x01000000)
  Run "work\rebased-gui (the accessories)" (@('py', '-3', $rb, 'work\sys', 'work\rebased-gui') + $base + $ug +
       @('cards.dll=0x20500000', 'mfc42u.dll=0x20600000', 'riched20.dll=0x20700000'))
  foreach ($e in 'winmine.exe', 'notepad.exe', 'calc.exe', 'clipbrd.exe', 'packager.exe', 'sol.exe', 'freecell.exe', 'mspaint.exe', 'wordpad.exe') {
    Run "  $e" @('py', '-3', $rb, 'work\sys', 'work\rebased-gui', $e)
  }
  # the shell's set (tools\lift_explorer.sh and lift_accessories.sh add the rest)
  Run "work\rebased-shell (explorer)" (@('py', '-3', $rb, 'work\sys', 'work\rebased-shell', 'explorer.exe=0x01000000') + $base + $ug +
       @('comctl32.dll=0x20800000', 'shlwapi.dll=0x20900000', 'shell32.dll=0x20A00000', 'browseui.dll=0x20D00000', 'shdocvw.dll=0x20E00000',
         'ole32.dll=0x21000000', 'oleaut32.dll=0x21100000', 'rpcrt4.dll=0x21200000', 'actxprxy.dll=0x21300000', 'desk.cpl=0x21400000',
         'clbcatq.dll=0x21500000', 'mydocs.dll=0x21600000'))
}

# ---------------------------------------------------------------- lift and build
# A program is done when its build\<target>.exe is there.
$Accessories = @('winmine', 'notepad', 'calc', 'clipbrd', 'packager', 'sol', 'freecell', 'mspaint', 'wordpad', 'charmap', 'sndrec32', 'winhlp32', 'cmd', 'find', 'more')
function Target($a) { if ($a -in 'cmd', 'find', 'more') { return $a } else { return "nt$a" } }
Step 5 "Lifting and building explorer and rundll32 (about 30 minutes)"
if ((Done 'build\ntexplorer.exe') -and (Test-Path 'build\ntrundll32.exe')) { Say "  Already done (skipping)." }
else { Sh "Lifting and building (work\lift_ntexplorer.log, work\build_ntexplorer.log)" 'sh tools/lift_explorer.sh' }

Step 6 "Lifting and building the accessories, cmd, find and more (about an hour)"
$todo = @($Accessories | Where-Object { $Force -or -not (Test-Path "build\$(Target $_).exe") })
if (-not $todo) { Say "  Already done (skipping)." }
foreach ($a in $todo) { Sh "$a (work\lift_$(Target $a).log)" "sh tools/lift_accessories.sh $a" }

Step 7 "Building (build.cmd)"
$missing = @(@('ntexplorer', 'ntrundll32') + ($Accessories | ForEach-Object { Target $_ }) | Where-Object { -not (Test-Path "build\$_.exe") })
if (-not $Force -and -not $missing) { Say "  Already built (skipping)." }
else { Run "Compiling" @('cmd', '/d', '/c', ('call "' + (Join-Path $Root 'build.cmd') + '"')) }
$missing = @(@('ntexplorer', 'ntrundll32') + ($Accessories | ForEach-Object { Target $_ }) | Where-Object { -not (Test-Path "build\$_.exe") })
if ($missing) { Fail "not built: $($missing -join ', ')." }

# ---------------------------------------------------------------- the box
# Explorer's registry box (HKCU\Software\pcrecomp\w2k\explorer: Windows 2000's COM classes and an
# App Path for each lifted runner) and its private profile in work\profile, the guest's C:\.
Step 8 "Explorer's registry box and profile (work\profile)"
$boxKey = 'HKCU:\Software\pcrecomp\w2k\explorer\HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\winmine.exe'
$profileDone = (Test-Path $boxKey) -and (Test-Path 'work\profile\C\Program Files\Internet Explorer\IEXPLORE.EXE') -and
               (Test-Path 'work\profile\C\Documents and Settings\all\Start Menu\Programs\Accessories')
if ($profileDone -and -not $Force) { Say "  Already done (skipping)." }
else {
  Run "Windows 2000's COM classes" @('py', '-3', 'tools\reginst.py', 'w2k\explorer', 'work\rebased-shell', 'browseui', 'shell32', 'shdocvw', 'comctl32', 'mydocs')
  # (the same as tools/run_explorer.sh does before each run)
  Sh "The profile" (@(
    "py -3 tools/profile.py 'w2k\explorer' 'work/profile/C/Documents and Settings' 'C:\Documents and Settings' >/dev/null",
    'mkdir -p work/profile/C/TEMP work/profile/C/WINNT/system32 work/profile/C/WINNT/Help',
    'for x in find.exe more.com charmap.exe clipbrd.exe sndrec32.exe winhlp32.exe; do : > work/profile/C/WINNT/system32/$x; done',
    '7z e -y -owork/profile/C/WINNT/Help work/iso/I386/CHARMAP.HL_ >/dev/null',
    "mkdir -p 'work/profile/C/Program Files/Internet Explorer'",
    "7z e -y '-owork/profile/C/Program Files/Internet Explorer' work/iso/I386/IEXPLORE.EX_ >/dev/null") -join ' && ')
}

# ---------------------------------------------------------------- the launcher
Step 9 "Making the shortcut, and starting explorer once, unseen"
$lnk = Join-Path $Root 'Windows 2000 (recomp).cmd'
# tools/run_explorer.sh's environment (the profile, the file box, muted), in a window of its own
Set-Content -Path $lnk -Encoding ASCII -Value @(
  '@echo off',
  'rem Windows 2000''s own explorer, recompiled, on an 800x600 screen of its own (W2K_SCREEN to change it).',
  'rem The guest sees only work\profile (its C:); the log is work\explorer.log. Close this window to quit.',
  'cd /d "%~dp0"',
  'set "B=%~dp0work\profile"',
  'set "P=%B%\C\Documents and Settings"',
  'if not defined W2K_SCREEN set W2K_SCREEN=800x600',
  'set PCRECOMP_MUTE=1',
  'set PCRECOMP_GUEST_PATH=C:\WINNT\system32',
  'set "PCRECOMP_FILEBOX=%B%"',
  'set "ProgramFiles=%B%\C\Program Files"',
  'set "CommonProgramFiles=%B%\C\Program Files\Common Files"',
  'set ProgramW6432=',
  'set CommonProgramW6432=',
  'set "USERPROFILE=%P%\user"',
  'set "ALLUSERSPROFILE=%P%\all"',
  'set "ProgramData=%P%\all"',
  'set "PUBLIC=%P%\all"',
  'set "APPDATA=%P%\user\Application Data"',
  'set "LOCALAPPDATA=%P%\user\Local Settings\Application Data"',
  'set HOMEDRIVE=',
  'set HOMEPATH=',
  'set "TEMP=%B%\C\TEMP"',
  'set "TMP=%B%\C\TEMP"',
  'title Windows 2000 (recomp)',
  'echo Windows 2000 is running in its own window. Close it, or this window, to quit.',
  'build\ntexplorer.exe --mute %* 2> work\explorer.log')
Say "  $lnk"
# ponytail: on a fresh registry box explorer's first two starts fault (in clbcatq) while they fill
# the box (Active Setup, proxy/stub interfaces); the third is clean. Done here, on explorer's own
# hidden desktop (--headless), so the first double-click works. Root cause not found yet.
if (Done 'work\first_start.ok') { Say "  First start already done (skipping)." }
else {
  $ok = $false
  foreach ($i in 1..4) {
    Exec @('cmd', '/d', '/c', ('call "' + $lnk + '" --headless --watchdog 20')) | Out-Null
    $clean = -not (Select-String -Quiet -SimpleMatch '=== fault' -Path 'work\explorer.log')
    Say "  start $($i): $(if ($clean) { 'clean' } else { 'faulted (the first starts fill the registry box)' })"
    if ($clean) { $ok = $true; break }
  }
  if (-not $ok) { Fail "explorer faulted on every start: see work\explorer.log." }
  Set-Content -Path 'work\first_start.ok' -Value "clean start $(Get-Date -Format s)"
}

# ---------------------------------------------------------------- Linux
if ($Linux) {
  Step 10 "Lifting the Linux sets: explorer, Paint, WordPad (about 30 minutes)"
  # Windows 2000's own advapi32 (no host registry on Linux) and comctl32 for MFC (docs/linux.md)
  if (-not (Test-Path 'work\lx\reb\advapi32.dll') -or $Force) {
    New-Item -ItemType Directory -Force work\lx\src | Out-Null
    Expand-Cd 'advapi32.dll' 'work\lx\src'; Expand-Cd 'comctl32.dll' 'work\lx\src'
    Run "work\lx\reb" @('py', '-3', (Join-Path $T 'pe\rebase.py'), 'work\lx\src', 'work\lx\reb', 'advapi32.dll=0x21F00000', 'comctl32.dll=0x20800000')
  }
  # the _lx sets' catalogs (work\cat-lx): work\cat's, but those with Linux seeds of their own are made again
  New-Item -ItemType Directory -Force work\cat-lx | Out-Null
  Get-ChildItem work\cat -Filter *.functions.json | Where-Object {
    -not (Test-Path "work\cat-lx\$($_.Name)") -and -not (Test-Path "work\seeds-lx\$($_.Name -replace '\.functions\.json$', '.json')") } |
    ForEach-Object { Copy-Item $_.FullName "work\cat-lx\$($_.Name)" }
  $R = 'work/rebased-shell'; $G = 'work/rebased-gui'
  $base = @("ntdll.dll", "kernel32.dll", "msvcrt.dll", "user32.dll", "gdi32.dll")
  $sets = @(
    @{ T = 'ntexplorer_lx'; M = @("$R/explorer.exe") + ($base | ForEach-Object { "$R/$_" }) + (@('comctl32.dll', 'shlwapi.dll', 'shell32.dll', 'browseui.dll',
        'shdocvw.dll', 'ole32.dll', 'oleaut32.dll', 'rpcrt4.dll', 'actxprxy.dll', 'clbcatq.dll', 'mydocs.dll') | ForEach-Object { "$R/$_" }) + @('work/lx/reb/advapi32.dll') },
    @{ T = 'ntmspaint_lx'; M = @("$G/mspaint.exe", "$G/mfc42u.dll", 'work/lx/reb/comctl32.dll') + ($base | ForEach-Object { "$G/$_" }) },
    @{ T = 'ntwordpad_lx'; M = @("$G/wordpad.exe", "$G/mfc42u.dll", "$G/riched20.dll", 'work/lx/reb/comctl32.dll') + ($base | ForEach-Object { "$G/$_" }) })
  foreach ($s in $sets) {
    if ((Done "src\gen\$($s.T)\recomp_dispatch.c")) { Say "  $($s.T): already lifted (skipping)."; continue }
    $code = Exec (@('py', '-3', 'tools\lift.py', $s.T) + $s.M)
    if ($code -ne 0) { Fail "lifting $($s.T) failed (exit code $code)." }
    Say "  $($s.T): lifted"
  }

  Step 11 "Filling work\linux, the folder ./setup.sh builds on Linux"
  if (Done 'work\linux\complete') { Say "  Already done (skipping)." }
  else {
    # the registry box as a file (ntposix's --regbox)
    $reg = Join-Path $Root 'work\lx\box.reg'
    Run "Exporting explorer's registry box" @('reg', 'export', 'HKCU\Software\pcrecomp\w2k\explorer', $reg, '/y')
    Run "work\lx\explorer.box" @('py', '-3', 'tools\regbox_lx.py', $reg, 'work\lx\explorer.box')
    if (Test-Path work\linux) { Remove-Item -Recurse -Force work\linux }
    # explorer, and the programs its Start menu and Run start (./NAME-linux beside it)
    foreach ($a in 'ntexplorer_lx', 'ntwinmine', 'ntnotepad', 'ntcalc', 'ntsol', 'ntfreecell', 'ntmspaint_lx', 'ntwordpad_lx') {
      Sh "  $a" "sh tools/linux_push.sh local work/linux '$env:PCRECOMP' $a"
    }
    Set-Content -Path work\linux\complete -Value "filled $(Get-Date -Format s)"   # (last: the folder is complete)
  }
}

Write-Host ""
Say "Done. Double-click 'Windows 2000 (recomp).cmd' to start Windows 2000's explorer." 'Green'
if ($Linux) { Say "For Linux: copy work\linux to work/linux in this repo on the Linux machine, then run ./setup.sh there." }
Pause-End
