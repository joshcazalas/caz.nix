#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Gate', 'Reconcile')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidatePattern('^S-1-5-21-(?:\d+-){3}\d+$')]
    [string]$RemoteAccountSid,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_. -]+$')]
    [string]$SunshineServiceName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('Caz.GameStream.SessionState' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Caz.GameStream {
    public sealed class SessionSnapshot {
        public uint SessionId { get; set; }
        public int LockState { get; set; }
        public string AccountName { get; set; }
    }

    public static class SessionState {
        private const uint NoSession = 0xFFFFFFFF;
        private const int WtsSessionInfoEx = 25;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WtsInfoExLevel1 {
            public uint SessionId;
            public int SessionState;
            public int SessionFlags;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 33)]
            public string WinStationName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)]
            public string UserName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 18)]
            public string DomainName;

            public long LogonTime;
            public long ConnectTime;
            public long DisconnectTime;
            public long LastInputTime;
            public long CurrentTime;
            public uint IncomingBytes;
            public uint OutgoingBytes;
            public uint IncomingFrames;
            public uint OutgoingFrames;
            public uint IncomingCompressedBytes;
            public uint OutgoingCompressedBytes;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WtsInfoEx {
            public uint Level;
            public WtsInfoExLevel1 Data;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll")]
        private static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WTSQuerySessionInformationW(
            IntPtr server,
            uint sessionId,
            int infoClass,
            out IntPtr buffer,
            out uint bytesReturned
        );

        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr memory);

        private static SessionSnapshot Query(uint sessionId) {
            if (sessionId == NoSession) {
                return new SessionSnapshot {
                    SessionId = NoSession,
                    LockState = -1,
                    AccountName = null
                };
            }

            IntPtr buffer;
            uint bytesReturned;
            if (!WTSQuerySessionInformationW(
                IntPtr.Zero,
                sessionId,
                WtsSessionInfoEx,
                out buffer,
                out bytesReturned
            )) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try {
                WtsInfoEx info = (WtsInfoEx)Marshal.PtrToStructure(
                    buffer,
                    typeof(WtsInfoEx)
                );
                if (info.Level != 1) {
                    throw new InvalidOperationException("Windows returned an unknown session information level.");
                }

                string accountName = null;
                if (!String.IsNullOrWhiteSpace(info.Data.UserName)) {
                    accountName = String.IsNullOrWhiteSpace(info.Data.DomainName)
                        ? info.Data.UserName
                        : info.Data.DomainName + "\\" + info.Data.UserName;
                }
                return new SessionSnapshot {
                    SessionId = sessionId,
                    LockState = info.Data.SessionFlags,
                    AccountName = accountName
                };
            }
            finally {
                WTSFreeMemory(buffer);
            }
        }

        public static SessionSnapshot Current() {
            uint sessionId;
            uint processId = (uint)Process.GetCurrentProcess().Id;
            if (!ProcessIdToSessionId(processId, out sessionId)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return Query(sessionId);
        }

        public static SessionSnapshot ActiveConsole() {
            return Query(WTSGetActiveConsoleSessionId());
        }
    }
}
'@
}

function Get-AccountSid {
    param([AllowNull()][string]$AccountName)

    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        return $null
    }
    try {
        $account = [Security.Principal.NTAccount]::new($AccountName)
        return $account.Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $null
    }
}

if ($Mode -eq 'Gate') {
    $snapshot = [Caz.GameStream.SessionState]::Current()
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($currentSid -eq $RemoteAccountSid -or $snapshot.LockState -eq 0) {
        exit 0
    }

    [Console]::Error.WriteLine('Remote play is unavailable while a non-remote Windows session is unlocked.')
    exit 23
}

$available = $false
try {
    $snapshot = [Caz.GameStream.SessionState]::ActiveConsole()
    if (
        $snapshot.SessionId -eq [uint32]::MaxValue -or
        [string]::IsNullOrWhiteSpace($snapshot.AccountName) -or
        $snapshot.LockState -eq 0
    ) {
        $available = $true
    }
    elseif ($snapshot.LockState -eq 1) {
        $available = (Get-AccountSid -AccountName $snapshot.AccountName) -eq $RemoteAccountSid
    }
}
catch {
    $available = $false
}

$service = Get-Service -Name $SunshineServiceName -ErrorAction Stop
if ($available) {
    if ($service.Status -ne 'Running') {
        Start-Service -Name $SunshineServiceName
    }
}
elseif ($service.Status -ne 'Stopped') {
    Stop-Service -Name $SunshineServiceName -Force
}
