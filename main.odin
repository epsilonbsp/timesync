package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

SERVICE_NAME :: "timesync"
SERVICE_DISPLAY_NAME :: "Timesync"
SERVICE_DESCRIPTION :: "Keeps the system clock synchronized with internet time servers (SNTP)."

SYNC_INTERVAL_MS :: 60 * 60 * 1000 // Resync every hour.
RETRY_INTERVAL_MS :: 60 * 1000 // Retry sooner when every server failed (e.g. network not up yet at boot).
NTP_TIMEOUT_MS :: 2000
NTP_SAMPLES :: 4 // Queries per server; the one with the lowest round trip wins.
MIN_ADJUST_TICKS :: 5000 // 0.5 ms, below this the clock is left alone.
LOG_MAX_SIZE :: 1024 * 1024

DEFAULT_SERVERS := [?]string{"pool.ntp.org", "time.cloudflare.com", "time.google.com", "time.windows.com"}

// Seconds between the NTP epoch (1900-01-01) and the FILETIME epoch (1601-01-01).
NTP_TO_FILETIME_SECONDS :: 9435484800
TICKS_PER_SECOND :: 10_000_000 // FILETIME ticks are 100 ns.

// ---------------------------------------------------------------------------
// Win32 bindings missing from core:sys/windows
// ---------------------------------------------------------------------------

foreign import advapi32 "system:Advapi32.lib"
foreign import kernel32 "system:Kernel32.lib"

SC_HANDLE :: distinct win.HANDLE
SERVICE_STATUS_HANDLE :: distinct win.HANDLE

SERVICE_STATUS :: struct {
    dwServiceType: win.DWORD,
    dwCurrentState: win.DWORD,
    dwControlsAccepted: win.DWORD,
    dwWin32ExitCode: win.DWORD,
    dwServiceSpecificExitCode: win.DWORD,
    dwCheckPoint: win.DWORD,
    dwWaitHint: win.DWORD,
}

SERVICE_MAIN_PROC :: #type proc "system" (argc: win.DWORD, argv: [^]win.wstring)
HANDLER_EX_PROC :: #type proc "system" (control, event_type: win.DWORD, event_data, ctx: rawptr) -> win.DWORD

SERVICE_TABLE_ENTRYW :: struct {
    lpServiceName: win.wstring,
    lpServiceProc: SERVICE_MAIN_PROC,
}

SERVICE_DESCRIPTIONW :: struct {
    lpDescription: win.wstring,
}

SC_ACTION :: struct {
    Type: win.DWORD,
    Delay: win.DWORD,
}

SERVICE_FAILURE_ACTIONSW :: struct {
    dwResetPeriod: win.DWORD,
    lpRebootMsg: win.wstring,
    lpCommand: win.wstring,
    cActions: win.DWORD,
    lpsaActions: [^]SC_ACTION,
}

TOKEN_PRIVILEGES_1 :: struct {
    PrivilegeCount: win.DWORD,
    Privileges: [1]win.LUID_AND_ATTRIBUTES,
}

DYNAMIC_TIME_ZONE_INFORMATION :: struct {
    Bias: win.LONG,
    StandardName: [32]win.WCHAR,
    StandardDate: win.SYSTEMTIME,
    StandardBias: win.LONG,
    DaylightName: [32]win.WCHAR,
    DaylightDate: win.SYSTEMTIME,
    DaylightBias: win.LONG,
    TimeZoneKeyName: [128]win.WCHAR,
    DynamicDaylightTimeDisabled: win.BOOLEAN,
}

SC_MANAGER_CONNECT :: 0x0001
SC_MANAGER_CREATE_SERVICE :: 0x0002

SERVICE_QUERY_STATUS :: 0x0004
SERVICE_START :: 0x0010
SERVICE_STOP :: 0x0020
SERVICE_ALL_ACCESS :: 0xF01FF
DELETE :: 0x10000

SERVICE_WIN32_OWN_PROCESS :: 0x10
SERVICE_AUTO_START :: 2
SERVICE_ERROR_NORMAL :: 1

SERVICE_CONFIG_DESCRIPTION :: 1
SERVICE_CONFIG_FAILURE_ACTIONS :: 2
SC_ACTION_RESTART :: 1

SERVICE_CONTROL_STOP :: 1
SERVICE_CONTROL_INTERROGATE :: 4
SERVICE_CONTROL_SHUTDOWN :: 5
SERVICE_ACCEPT_STOP :: 0x1
SERVICE_ACCEPT_SHUTDOWN :: 0x4

SERVICE_STOPPED :: 1
SERVICE_START_PENDING :: 2
SERVICE_STOP_PENDING :: 3
SERVICE_RUNNING :: 4
SERVICE_CONTINUE_PENDING :: 5
SERVICE_PAUSE_PENDING :: 6
SERVICE_PAUSED :: 7

ERROR_NOT_ALL_ASSIGNED :: 1300
ERROR_SERVICE_DOES_NOT_EXIST :: 1060
ERROR_SERVICE_NOT_ACTIVE :: 1062
ERROR_FAILED_SERVICE_CONTROLLER_CONNECT :: 1063
ERROR_SERVICE_MARKED_FOR_DELETE :: 1072
ERROR_SERVICE_EXISTS :: 1073
ERROR_CANCELLED :: 1223

SE_PRIVILEGE_ENABLED :: 0x2
SE_SYSTEMTIME_NAME :: "SeSystemtimePrivilege"

TIME_ZONE_ID_DAYLIGHT :: 2
TIME_ZONE_ID_INVALID :: 0xFFFFFFFF

@(default_calling_convention = "system")
foreign advapi32 {
    OpenSCManagerW :: proc(lpMachineName, lpDatabaseName: win.wstring, dwDesiredAccess: win.DWORD) -> SC_HANDLE ---
    CreateServiceW :: proc(
        hSCManager: SC_HANDLE,
        lpServiceName, lpDisplayName: win.wstring,
        dwDesiredAccess, dwServiceType, dwStartType, dwErrorControl: win.DWORD,
        lpBinaryPathName, lpLoadOrderGroup: win.wstring,
        lpdwTagId: ^win.DWORD,
        lpDependencies, lpServiceStartName, lpPassword: win.wstring,
    ) -> SC_HANDLE ---
    OpenServiceW :: proc(hSCManager: SC_HANDLE, lpServiceName: win.wstring, dwDesiredAccess: win.DWORD) -> SC_HANDLE ---
    CloseServiceHandle :: proc(hSCObject: SC_HANDLE) -> win.BOOL ---
    DeleteService :: proc(hService: SC_HANDLE) -> win.BOOL ---
    StartServiceW :: proc(hService: SC_HANDLE, dwNumServiceArgs: win.DWORD, lpServiceArgVectors: [^]win.wstring) -> win.BOOL ---
    ControlService :: proc(hService: SC_HANDLE, dwControl: win.DWORD, lpServiceStatus: ^SERVICE_STATUS) -> win.BOOL ---
    QueryServiceStatus :: proc(hService: SC_HANDLE, lpServiceStatus: ^SERVICE_STATUS) -> win.BOOL ---
    ChangeServiceConfig2W :: proc(hService: SC_HANDLE, dwInfoLevel: win.DWORD, lpInfo: rawptr) -> win.BOOL ---
    StartServiceCtrlDispatcherW :: proc(lpServiceStartTable: [^]SERVICE_TABLE_ENTRYW) -> win.BOOL ---
    RegisterServiceCtrlHandlerExW :: proc(lpServiceName: win.wstring, lpHandlerProc: HANDLER_EX_PROC, lpContext: rawptr) -> SERVICE_STATUS_HANDLE ---
    SetServiceStatus :: proc(hServiceStatus: SERVICE_STATUS_HANDLE, lpServiceStatus: ^SERVICE_STATUS) -> win.BOOL ---
    LookupPrivilegeValueW :: proc(lpSystemName, lpName: win.wstring, lpLuid: ^win.LUID) -> win.BOOL ---
    AdjustTokenPrivileges :: proc(
        TokenHandle: win.HANDLE,
        DisableAllPrivileges: win.BOOL,
        NewState: ^TOKEN_PRIVILEGES_1,
        BufferLength: win.DWORD,
        PreviousState: rawptr,
        ReturnLength: ^win.DWORD,
    ) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign kernel32 {
    SetSystemTime :: proc(lpSystemTime: ^win.SYSTEMTIME) -> win.BOOL ---
    GetDynamicTimeZoneInformation :: proc(pTimeZoneInformation: ^DYNAMIC_TIME_ZONE_INFORMATION) -> win.DWORD ---
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

g_is_service: bool
g_stop_event: win.HANDLE
g_status_handle: SERVICE_STATUS_HANDLE
g_status: SERVICE_STATUS

main :: proc() {
    wsa: win.WSADATA

    if win.WSAStartup(0x0202, &wsa) != 0 {
        fmt.eprintln("error: failed to initialize Winsock")
        os.exit(1)
    }

    defer win.WSACleanup()

    args := os.args[1:]

    // The elevated copy started by run_elevated writes its output to a file for the original process to print.
    if len(args) >= 2 && args[0] == "--output" {
        f, err := os.open(args[1], os.O_WRONLY | os.O_CREATE | os.O_TRUNC)

        if err == nil {
            os.stdout = f
            os.stderr = f
        }

        args = args[2:]
    }

    command := len(args) > 0 ? args[0] : "help"
    arg := len(args) > 1 ? args[1] : ""
    ok := true

    if (command == "install" || command == "uninstall" || command == "sync") && !is_elevated() {
        os.exit(run_elevated(args))
    }

    switch command {
    case "help", "-h", "--help", "/?":
        print_help()
    case "install":
        ok = cmd_install()
    case "uninstall":
        ok = cmd_uninstall()
    case "status":
        ok = cmd_status(arg)
    case "sync":
        ok = cmd_sync(arg)
    case "service":
        ok = cmd_service()
    case:
        fmt.eprintf("error: unknown command '%s'\n\n", command)
        print_help()
        ok = false
    }

    if !ok {
        os.exit(1)
    }
}

print_help :: proc() {
    fmt.println(`timesync - keeps the Windows clock synchronized with internet time servers

Usage: timesync <command> [server]

Commands:
  help              Print this help
  install           Install and start the background service (starts on boot)
  uninstall         Stop and remove the background service
  status            Show clock offset, time zone and service state
  sync [server]     Synchronize the clock now

install, uninstall and sync require administrator rights and will show a UAC prompt
when run from a non-elevated terminal.`)
    fmt.printf("\nDefault servers: %s\n", strings.join(DEFAULT_SERVERS[:], ", ", context.temp_allocator))
    fmt.printf("Log file:        %s\n", log_path())
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

cmd_install :: proc() -> bool {
    exe, err := os.get_executable_path(context.temp_allocator)

    if err != nil {
        fmt.eprintln("error: cannot determine executable path")

        return false
    }

    scm := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE)

    if scm == nil {
        print_win_error("cannot open service manager")

        return false
    }

    defer CloseServiceHandle(scm)

    bin_path := fmt.tprintf(`"%s" service`, exe)
    svc := CreateServiceW(
        scm,
        win.L(SERVICE_NAME),
        win.L(SERVICE_DISPLAY_NAME),
        SERVICE_ALL_ACCESS,
        SERVICE_WIN32_OWN_PROCESS,
        SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL,
        win.utf8_to_wstring(bin_path),
        nil,
        nil,
        nil,
        nil,
        nil,
    )

    if svc == nil {
        if win.GetLastError() == ERROR_SERVICE_EXISTS {
            fmt.println("Service is already installed. Run 'timesync uninstall' first to reinstall.")
        } else {
            print_win_error("cannot create service")
        }

        return false
    }

    defer CloseServiceHandle(svc)

    desc := SERVICE_DESCRIPTIONW{win.L(SERVICE_DESCRIPTION)}
    ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, &desc)

    // Restart the service if it ever crashes.
    actions := [3]SC_ACTION{{SC_ACTION_RESTART, 60_000}, {SC_ACTION_RESTART, 60_000}, {SC_ACTION_RESTART, 60_000}}
    failure := SERVICE_FAILURE_ACTIONSW{dwResetPeriod = 24 * 60 * 60, cActions = len(actions), lpsaActions = &actions[0]}
    ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, &failure)

    fmt.printf("Service '%s' installed (%s).\n", SERVICE_NAME, bin_path)
    fmt.println("Note: the service runs this executable from its current location, so don't move or delete it.")

    if !StartServiceW(svc, 0, nil) {
        print_win_error("service installed but failed to start")

        return false
    }

    fmt.println("Service started. The clock will be synchronized now and every hour.")

    return true
}

cmd_uninstall :: proc() -> bool {
    scm := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT)

    if scm == nil {
        print_win_error("cannot open service manager")

        return false
    }

    defer CloseServiceHandle(scm)

    svc := OpenServiceW(scm, win.L(SERVICE_NAME), SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE)

    if svc == nil {
        if win.GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST {
            fmt.println("Service is not installed.")

            return true
        }

        print_win_error("cannot open service")

        return false
    }

    defer CloseServiceHandle(svc)

    status: SERVICE_STATUS

    if ControlService(svc, SERVICE_CONTROL_STOP, &status) {
        fmt.print("Stopping service")

        for _ in 0 ..< 60 {
            if !QueryServiceStatus(svc, &status) || status.dwCurrentState == SERVICE_STOPPED {
                break
            }

            fmt.print(".")
            win.Sleep(250)
        }

        fmt.println()
    } else if win.GetLastError() != ERROR_SERVICE_NOT_ACTIVE {
        print_win_error("cannot stop service")
    }

    if !DeleteService(svc) {
        if win.GetLastError() == ERROR_SERVICE_MARKED_FOR_DELETE {
            fmt.println("Service is already marked for deletion.")

            return true
        }

        print_win_error("cannot delete service")

        return false
    }

    fmt.printf("Service '%s' uninstalled.\n", SERVICE_NAME)

    return true
}

cmd_sync :: proc(server: string) -> bool {
    servers := server != "" ? []string{server} : DEFAULT_SERVERS[:]

    return sync_clock(servers)
}

cmd_status :: proc(server: string) -> bool {
    ticks := now_ticks()
    utc := ticks_to_systemtime(ticks)
    local: win.SYSTEMTIME
    win.SystemTimeToTzSpecificLocalTime(nil, &utc, &local)

    WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
    fmt.printf("Local time:    %s (%s)\n", format_systemtime(local), WEEKDAYS[local.day_of_week % 7])
    fmt.printf("UTC time:      %s\n", format_systemtime(utc))

    tz: DYNAMIC_TIME_ZONE_INFORMATION
    tz_id := GetDynamicTimeZoneInformation(&tz)

    if tz_id != TIME_ZONE_ID_INVALID {
        daylight := tz_id == TIME_ZONE_ID_DAYLIGHT
        bias := tz.Bias + (daylight ? tz.DaylightBias : tz.StandardBias)
        utc_offset := -bias
        sign := utc_offset < 0 ? '-' : '+'
        utc_offset = abs(utc_offset)
        name := daylight ? tz.DaylightName[:] : tz.StandardName[:]
        fmt.printf("Time zone:     %s (UTC%c%02d:%02d)\n", wide_to_string(tz.TimeZoneKeyName[:]), sign, utc_offset / 60, utc_offset % 60)
        fmt.printf("               %s%s\n", wide_to_string(name), daylight ? ", daylight saving time in effect" : "")
    }

    servers := server != "" ? []string{server} : DEFAULT_SERVERS[:]
    measured := false

    for s in servers {
        offset, delay, ok := ntp_query(s)

        if !ok {
            continue
        }

        seconds := f64(offset) / TICKS_PER_SECOND
        fmt.printf("Clock offset:  %+.4f s vs %s (round trip %.1f ms)\n", seconds, s, f64(delay) / 10_000)
        fmt.printf("               %s\n", describe_offset(seconds))
        measured = true

        break
    }

    if !measured {
        fmt.println("Clock offset:  unknown (no time server responded)")
    }

    fmt.printf("Service:       %s\n", service_state_string(SERVICE_NAME))
    w32 := service_state_string("w32time")
    fmt.printf("Windows Time:  %s\n", w32)

    if w32 == "running" {
        fmt.println("               (w32time also adjusts the clock; consider disabling it while timesync is installed)")
    }

    if last := last_log_line(); last != "" {
        fmt.printf("Last log:      %s\n", last)
    }

    return true
}

cmd_service :: proc() -> bool {
    g_is_service = true
    table := [2]SERVICE_TABLE_ENTRYW{{win.L(SERVICE_NAME), service_main}, {}}

    if !StartServiceCtrlDispatcherW(&table[0]) {
        if win.GetLastError() == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT {
            fmt.eprintln("error: 'service' is run by the Windows service manager. Use 'timesync install' instead.")
        } else {
            print_win_error("service dispatcher failed")
        }

        return false
    }

    return true
}

// ---------------------------------------------------------------------------
// Elevation
// ---------------------------------------------------------------------------

is_elevated :: proc() -> bool {
    token: win.HANDLE

    if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) {
        return false
    }

    defer win.CloseHandle(token)

    elevated: win.DWORD
    size: win.DWORD

    if !win.GetTokenInformation(token, .TokenElevation, &elevated, size_of(elevated), &size) {
        return false
    }

    return elevated != 0
}

// Reruns this executable with the given arguments as administrator (shows a UAC prompt),
// waits for it to finish, prints its output and returns its exit code.
run_elevated :: proc(args: []string) -> int {
    exe, err := os.get_executable_path(context.temp_allocator)

    if err != nil {
        fmt.eprintln("error: cannot determine executable path")

        return 1
    }

    temp_dir, _ := os.temp_directory(context.temp_allocator)
    output_path := fmt.tprintf(`%s\timesync-%d.out`, strings.trim_right(temp_dir, `\`), win.GetCurrentProcessId())

    params := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&params, `--output "%s"`, output_path)

    for a in args {
        fmt.sbprintf(&params, ` "%s"`, a)
    }

    info := win.SHELLEXECUTEINFOW{
        cbSize = size_of(win.SHELLEXECUTEINFOW),
        fMask = win.SEE_MASK_NOCLOSEPROCESS | win.SEE_MASK_NOASYNC,
        lpVerb = win.L("runas"),
        lpFile = win.utf8_to_wstring(exe),
        lpParameters = win.utf8_to_wstring(strings.to_string(params)),
        nShow = win.SW_HIDE,
    }

    if !win.ShellExecuteExW(&info) {
        if win.GetLastError() == ERROR_CANCELLED {
            fmt.eprintln("error: administrator rights are required, the UAC prompt was declined")
        } else {
            print_win_error("cannot start elevated process")
        }

        return 1
    }

    defer win.CloseHandle(info.hProcess)

    exit_code: win.DWORD
    win.WaitForSingleObject(info.hProcess, win.INFINITE)
    win.GetExitCodeProcess(info.hProcess, &exit_code)

    if data, read_err := os.read_entire_file(output_path, context.temp_allocator); read_err == nil {
        fmt.print(string(data))
    }

    os.remove(output_path)

    return int(exit_code)
}

// ---------------------------------------------------------------------------
// Windows service
// ---------------------------------------------------------------------------

service_main :: proc "system" (argc: win.DWORD, argv: [^]win.wstring) {
    context = runtime.default_context()
    g_status_handle = RegisterServiceCtrlHandlerExW(win.L(SERVICE_NAME), service_control, nil)

    if g_status_handle == nil {
        return
    }

    g_stop_event = win.CreateEventW(nil, true, false, nil)
    set_service_state(SERVICE_RUNNING)
    log_line("service started")

    for {
        ok := sync_clock(DEFAULT_SERVERS[:])
        free_all(context.temp_allocator)
        wait: win.DWORD = ok ? SYNC_INTERVAL_MS : RETRY_INTERVAL_MS

        if win.WaitForSingleObject(g_stop_event, wait) == win.WAIT_OBJECT_0 {
            break
        }
    }

    log_line("service stopped")
    win.CloseHandle(g_stop_event)
    set_service_state(SERVICE_STOPPED)
}

service_control :: proc "system" (control, event_type: win.DWORD, event_data, ctx: rawptr) -> win.DWORD {
    context = runtime.default_context()

    switch control {
    case SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN:
        set_service_state(SERVICE_STOP_PENDING)
        win.SetEvent(g_stop_event)

        return win.NO_ERROR
    case SERVICE_CONTROL_INTERROGATE:
        return win.NO_ERROR
    }

    return win.ERROR_CALL_NOT_IMPLEMENTED
}

set_service_state :: proc(state: win.DWORD) {
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS
    g_status.dwCurrentState = state
    g_status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0
    g_status.dwWin32ExitCode = win.NO_ERROR
    g_status.dwWaitHint = state == SERVICE_STOP_PENDING ? 10_000 : 0
    SetServiceStatus(g_status_handle, &g_status)
}

stop_requested :: proc() -> bool {
    return g_stop_event != nil && win.WaitForSingleObject(g_stop_event, 0) == win.WAIT_OBJECT_0
}

service_state_string :: proc(name: string) -> string {
    scm := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT)

    if scm == nil {
        return "unknown"
    }

    defer CloseServiceHandle(scm)

    svc := OpenServiceW(scm, win.utf8_to_wstring(name), SERVICE_QUERY_STATUS)

    if svc == nil {
        return win.GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST ? "not installed" : "unknown"
    }

    defer CloseServiceHandle(svc)

    status: SERVICE_STATUS

    if !QueryServiceStatus(svc, &status) {
        return "unknown"
    }

    switch status.dwCurrentState {
    case SERVICE_STOPPED:
        return "stopped"
    case SERVICE_START_PENDING:
        return "starting"
    case SERVICE_STOP_PENDING:
        return "stopping"
    case SERVICE_RUNNING:
        return "running"
    case SERVICE_CONTINUE_PENDING:
        return "resuming"
    case SERVICE_PAUSE_PENDING:
        return "pausing"
    case SERVICE_PAUSED:
        return "paused"
    }

    return "unknown"
}

// ---------------------------------------------------------------------------
// Synchronization
// ---------------------------------------------------------------------------

sync_clock :: proc(servers: []string) -> bool {
    for server in servers {
        if stop_requested() {
            return false
        }

        offset, delay, ok := ntp_query(server)

        if !ok {
            log_line("%s: no valid response", server)

            continue
        }

        seconds := f64(offset) / TICKS_PER_SECOND
        delay_ms := f64(delay) / 10_000

        if abs(offset) < MIN_ADJUST_TICKS {
            log_line("clock already in sync (offset %+.4f s, %s, round trip %.1f ms)", seconds, server, delay_ms)

            return true
        }

        if !enable_privilege(SE_SYSTEMTIME_NAME) {
            log_line("error: missing permission to set the clock, run from an administrator prompt (offset is %+.4f s)", seconds)

            return false
        }

        if !set_clock(now_ticks() + offset) {
            log_line("error: failed to set the clock (error %d)", win.GetLastError())

            return false
        }

        log_line("clock adjusted by %+.4f s (%s, round trip %.1f ms)", seconds, server, delay_ms)

        return true
    }

    log_line("error: no time server responded")

    return false
}

// Queries an SNTP server several times and returns the clock offset (server - local)
// and round trip delay of the sample with the smallest delay, both in 100 ns ticks.
ntp_query :: proc(host: string) -> (offset, delay: i64, ok: bool) {
    hints := win.ADDRINFOA{ai_family = win.AF_INET, ai_socktype = win.SOCK_DGRAM, ai_protocol = win.IPPROTO_UDP}
    res: ^win.ADDRINFOA

    if win.getaddrinfo(strings.clone_to_cstring(host, context.temp_allocator), "123", &hints, &res) != 0 || res == nil {
        return
    }

    defer win.freeaddrinfo(res)

    sock := win.socket(win.AF_INET, win.SOCK_DGRAM, win.IPPROTO_UDP)

    if sock == win.INVALID_SOCKET {
        return
    }

    defer win.closesocket(sock)

    timeout: win.DWORD = NTP_TIMEOUT_MS
    win.setsockopt(sock, win.SOL_SOCKET, win.SO_RCVTIMEO, &timeout, size_of(timeout))

    // Connecting a UDP socket makes it discard datagrams from any other address.
    if win.connect(sock, cast(^win.SOCKADDR_STORAGE_LH)res.ai_addr, win.c_int(res.ai_addrlen)) != 0 {
        return
    }

    best_delay := max(i64)

    for _ in 0 ..< NTP_SAMPLES {
        request: [48]u8
        request[0] = 0x23 // LI = 0, version = 4, mode = 3 (client)

        t1 := now_ticks()
        // The server copies our transmit timestamp into its originate field, which lets us
        // match the reply to this request.
        write_ntp_timestamp(request[40:48], t1)

        if win.send(sock, &request, len(request), 0) != len(request) {
            continue
        }

        reply: [128]u8
        n := win.recv(sock, &reply, len(reply), 0)
        t4 := now_ticks()

        if n < 48 {
            continue
        }

        mode := reply[0] & 0x7
        leap := reply[0] >> 6
        stratum := reply[1]

        if mode != 4 || leap == 3 || stratum == 0 || stratum > 15 {
            continue
        }

        if (^u64)(&reply[24])^ != (^u64)(&request[40])^ {
            continue
        }

        t2 := read_ntp_timestamp(reply[32:40]) // server receive time
        t3 := read_ntp_timestamp(reply[40:48]) // server transmit time
        d := (t4 - t1) - (t3 - t2)

        if d < 0 {
            d = 0
        }

        if d < best_delay {
            best_delay = d
            offset = ((t2 - t1) + (t3 - t4)) / 2
            delay = d
            ok = true
        }
    }

    return
}

write_ntp_timestamp :: proc(buf: []u8, ticks: i64) {
    seconds := u64(ticks / TICKS_PER_SECOND - NTP_TO_FILETIME_SECONDS)
    fraction := (u64(ticks % TICKS_PER_SECOND) << 32) / TICKS_PER_SECOND
    (^u32be)(&buf[0])^ = u32be(seconds)
    (^u32be)(&buf[4])^ = u32be(fraction)
}

read_ntp_timestamp :: proc(buf: []u8) -> i64 {
    seconds := u64((^u32be)(&buf[0])^)
    fraction := u64((^u32be)(&buf[4])^)

    // NTP seconds wrap around in February 2036; small values belong to the next era.
    if seconds < 0x8000_0000 {
        seconds += 1 << 32
    }

    return i64(seconds + NTP_TO_FILETIME_SECONDS) * TICKS_PER_SECOND + i64((fraction * TICKS_PER_SECOND) >> 32)
}

// ---------------------------------------------------------------------------
// Clock helpers
// ---------------------------------------------------------------------------

now_ticks :: proc() -> i64 {
    ft: win.FILETIME
    win.GetSystemTimePreciseAsFileTime(&ft)

    return i64(u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime))
}

ticks_to_systemtime :: proc(ticks: i64) -> (st: win.SYSTEMTIME) {
    ft := win.FILETIME{dwLowDateTime = win.DWORD(u64(ticks) & 0xFFFF_FFFF), dwHighDateTime = win.DWORD(u64(ticks) >> 32)}
    win.FileTimeToSystemTime(&ft, &st)

    return
}

set_clock :: proc(ticks: i64) -> bool {
    // SYSTEMTIME only has millisecond resolution, so round to the nearest millisecond.
    st := ticks_to_systemtime(ticks + 5000)

    return bool(SetSystemTime(&st))
}

enable_privilege :: proc(name: string) -> bool {
    token: win.HANDLE

    if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_ADJUST_PRIVILEGES | win.TOKEN_QUERY, &token) {
        return false
    }

    defer win.CloseHandle(token)

    tp := TOKEN_PRIVILEGES_1{PrivilegeCount = 1}

    if !LookupPrivilegeValueW(nil, win.utf8_to_wstring(name), &tp.Privileges[0].Luid) {
        return false
    }

    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED

    if !AdjustTokenPrivileges(token, false, &tp, 0, nil, nil) {
        return false
    }

    // AdjustTokenPrivileges succeeds even when the privilege isn't held.
    return win.GetLastError() != ERROR_NOT_ALL_ASSIGNED
}

describe_offset :: proc(seconds: f64) -> string {
    a := abs(seconds)

    switch {
    case a < 0.05:
        return "clock is in sync"
    case a < 1:
        return "clock is slightly off, run 'timesync sync' to correct it"
    }

    return fmt.tprintf("clock is %s by %.1f s, run 'timesync sync' to correct it", seconds > 0 ? "behind" : "ahead", a)
}

format_systemtime :: proc(st: win.SYSTEMTIME) -> string {
    return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d.%03d", st.year, st.month, st.day, st.hour, st.minute, st.second, st.milliseconds)
}

wide_to_string :: proc(w: []win.WCHAR) -> string {
    s, _ := win.utf16_to_utf8(w, context.temp_allocator)

    return strings.trim_right_null(s)
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

log_path :: proc() -> string {
    dir := os.get_env("ProgramData", context.temp_allocator)

    if dir == "" {
        dir = `C:\ProgramData`
    }

    return fmt.tprintf(`%s\timesync\timesync.log`, dir)
}

// Prints the message (unless running as a service) and appends it to the log file.
log_line :: proc(format: string, args: ..any) {
    msg := fmt.tprintf(format, ..args)

    if !g_is_service {
        fmt.println(msg)
    }

    utc := ticks_to_systemtime(now_ticks())
    local: win.SYSTEMTIME
    win.SystemTimeToTzSpecificLocalTime(nil, &utc, &local)
    line := fmt.tprintf("%s  %s%s\r\n", format_systemtime(local), g_is_service ? "" : "[manual] ", msg)

    path := log_path()
    dir := path[:strings.last_index_byte(path, '\\')]
    os.make_directory_all(dir)

    flags := os.O_WRONLY | os.O_CREATE | os.O_APPEND

    if info, err := os.stat(path, context.temp_allocator); err == nil && info.size > LOG_MAX_SIZE {
        flags = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
    }

    f, err := os.open(path, flags)

    // Logging is best effort (e.g. non-admin users can't write to ProgramData).
    if err != nil {
        return
    }

    defer os.close(f)

    os.write_string(f, line)
}

last_log_line :: proc() -> string {
    data, err := os.read_entire_file(log_path(), context.temp_allocator)

    if err != nil {
        return ""
    }

    text := strings.trim_right_space(string(data))

    if i := strings.last_index_byte(text, '\n'); i >= 0 {
        text = text[i + 1:]
    }

    return strings.trim_space(text)
}

print_win_error :: proc(what: string) {
    code := win.GetLastError()

    if code == win.ERROR_ACCESS_DENIED {
        fmt.eprintf("error: %s: access denied (run from an administrator prompt)\n", what)
    } else {
        fmt.eprintf("error: %s (error %d)\n", what, code)
    }
}
