unit MemoryMap.Threads;

interface

uses
  Winapi.Windows,
  Generics.Collections,
  Winapi.TlHelp32,
  Winapi.ImageHlp,
  MemoryMap.NtDll;

type
  TThreadInfo = (tiNoData, tiExceptionList, tiStackBase,
    tiStackLimit, tiTEB, tiThreadProc);

const
  ThreadInfoStr: array [TThreadInfo] of string = ('UnknownThreadData',
    'Thread Exception List', 'Thread Stack Base', 'Thread Stack Limit',
    'TEB', 'ThreadProc');

type
  TThreadData = record
    Flag: TThreadInfo;
    ThreadID: Integer;
    Address: Pointer;
    Wow64: Boolean;
  end;

type
  LPADDRESS64 = ^ADDRESS64;
  {$EXTERNALSYM PADDRESS64}
  _tagADDRESS64 = record
    Offset: DWORD64;
    Segment: WORD;
    Mode: ADDRESS_MODE;
  end;
  {$EXTERNALSYM _tagADDRESS64}
  ADDRESS64 = _tagADDRESS64;
  {$EXTERNALSYM ADDRESS64}
  TAddress64 = ADDRESS64;
  PAddress64 = LPADDRESS64;

  PKDHELP64 = ^KDHELP64;
  {$EXTERNALSYM PKDHELP64}
  _KDHELP64 = record
    Thread: DWORD64;
    ThCallbackStack: DWORD;
    ThCallbackBStore: DWORD;
    NextCallback: DWORD;
    FramePointer: DWORD;
    KiCallUserMode: DWORD64;
    KeUserCallbackDispatcher: DWORD64;
    SystemRangeStart: DWORD64;
    KiUserExceptionDispatcher: DWORD64;
    StackBase: DWORD64;
    StackLimit: DWORD64;
    Reserved: array [0..4] of DWORD64;
  end;
  {$EXTERNALSYM _KDHELP64}
  KDHELP64 = _KDHELP64;
  {$EXTERNALSYM KDHELP64}
  TKdHelp64 = KDHELP64;

  LPSTACKFRAME64 = ^STACKFRAME64;
  {$EXTERNALSYM LPSTACKFRAME64}
  _tagSTACKFRAME64 = record
    AddrPC: ADDRESS64; // program counter
    AddrReturn: ADDRESS64; // return address
    AddrFrame: ADDRESS64; // frame pointer
    AddrStack: ADDRESS64; // stack pointer
    AddrBStore: ADDRESS64; // backing store pointer
    FuncTableEntry: PVOID; // pointer to pdata/fpo or NULL
    Params: array [0..3] of DWORD64; // possible arguments to the function
    Far: BOOL; // WOW far call
    Virtual: BOOL; // is this a virtual frame?
    Reserved: array [0..2] of DWORD64;
    KdHelp: KDHELP64;
  end;
  {$EXTERNALSYM _tagSTACKFRAME64}
  STACKFRAME64 = _tagSTACKFRAME64;
  {$EXTERNALSYM STACKFRAME64}
  TStackFrame64 = STACKFRAME64;
  PStackFrame64 = LPSTACKFRAME64;

  TThreadStackEntry = record
    ThreadID: Integer;
    Data: TStackFrame64;
    FuncName: ShortString;
    Wow64: Boolean;
    procedure SetFuncName(const Value: string);
  end;

  TSEHEntry = record
    ThreadID: Integer;
    Address: Pointer;
    Previous: Pointer;
    Handler: Pointer;
    HandlerName: ShortString;
    Wow64: Boolean;
    procedure SetHandlerName(const Value: string);
  end;

  TThreads = class
  private
    FThreadData: TList<TThreadData>;
    FThreadStackEntries: TList<TThreadStackEntry>;
    FSEH: TList<TSEHEntry>;
  protected
    procedure Add(hProcess: THandle;
      Flag: TThreadInfo; Address: Pointer; ID: Integer);
    procedure Update(PID: Cardinal; hProcess: THandle);
    procedure GetThreadCallStack(hProcess, hThread: THandle; ID: Integer);
    procedure GetThreadSEHFrames(hProcess: THandle; InitialAddr: Pointer; ID: Integer);
  public
    constructor Create; overload;
    constructor Create(PID: Cardinal; hProcess: THandle); overload;
    destructor Destroy; override;
    property SEHEntries: TList<TSEHEntry> read FSEH;
    property ThreadData: TList<TThreadData> read FThreadData;
    property ThreadStackEntries: TList<TThreadStackEntry> read FThreadStackEntries;
  end;

implementation

uses
  MemoryMap.Core;


{ TThreadStackEntry }

procedure TThreadStackEntry.SetFuncName(const Value: string);
begin
  FuncName := ShortString(Value);
end;

{ TThreadSehEntry }

procedure TSEHEntry.SetHandlerName(const Value: string);
begin
  HandlerName := ShortString(Value);
end;

{ TThreads }

procedure TThreads.Add(hProcess: THandle;
  Flag: TThreadInfo; Address: Pointer; ID: Integer);
var
  ThreadData: TThreadData;
begin
  if Address = nil then Exit;
  ThreadData.Flag := Flag;
  ThreadData.ThreadID := ID;
  ThreadData.Address := Address;
  ThreadData.Wow64 := False;
  FThreadData.Add(ThreadData);
end;

constructor TThreads.Create(PID: Cardinal; hProcess: THandle);
begin
  Create;
  Update(PID, hProcess);
end;

constructor TThreads.Create;
begin
  FSEH := TList<TSEHEntry>.Create;
  FThreadData := TList<TThreadData>.Create;
  FThreadStackEntries := TList<TThreadStackEntry>.Create;
end;

destructor TThreads.Destroy;
begin
  FSEH.Free;
  FThreadStackEntries.Free;
  FThreadData.Free;
  inherited;
end;

  function StackWalk64(MachineType: DWORD; hProcess: HANDLE; hThread: HANDLE;
    var StackFrame: STACKFRAME64; ContextRecord: PVOID;
    ReadMemoryRoutine: PVOID; FunctionTableAccessRoutine: PVOID;
    GetModuleBaseRoutine: PVOID; TranslateAddress: PVOID): BOOL; stdcall;
    external 'imagehlp.dll';

procedure TThreads.GetThreadCallStack(hProcess, hThread: THandle;
  ID: Integer);

  function ConvertStackFrameToStackFrame64(Value: TStackFrame): TStackFrame64;
  begin
    Result.AddrPC.Offset := Value.AddrPC.Offset;
    Result.AddrPC.Segment := Value.AddrPC.Segment;
    Result.AddrPC.Mode := Value.AddrPC.Mode;
    Result.AddrReturn.Offset := Value.AddrReturn.Offset;
    Result.AddrReturn.Segment := Value.AddrReturn.Segment;
    Result.AddrReturn.Mode := Value.AddrPC.Mode;
    Result.AddrFrame.Offset := Value.AddrFrame.Offset;
    Result.AddrFrame.Segment := Value.AddrFrame.Segment;
    Result.AddrFrame.Mode := Value.AddrFrame.Mode;
    Result.AddrStack.Offset := Value.AddrStack.Offset;
    Result.AddrStack.Segment := Value.AddrStack.Segment;
    Result.AddrStack.Mode := Value.AddrStack.Mode;
    Result.AddrBStore.Offset := Value.AddrBStore.Offset;
    Result.AddrBStore.Segment := Value.AddrBStore.Segment;
    Result.AddrBStore.Mode := Value.AddrBStore.Mode;
    Result.FuncTableEntry := Value.FuncTableEntry;
    Result.Params[0] := Value.Params[0];
    Result.Params[1] := Value.Params[1];
    Result.Params[2] := Value.Params[2];
    Result.Params[3] := Value.Params[3];
    Result.Far := Value._Far;
    Result.Virtual := Value._Virtual;
    Result.KdHelp.Thread := Value.KdHelp.Thread;
    Result.KdHelp.ThCallbackStack := Value.KdHelp.ThCallbackStack;
    Result.KdHelp.ThCallbackBStore := Value.KdHelp.ThCallbackBStore;
    Result.KdHelp.NextCallback := Value.KdHelp.NextCallback;
    Result.KdHelp.FramePointer := Value.KdHelp.FramePointer;
    Result.KdHelp.KiCallUserMode := Value.KdHelp.KiCallUserMode;
    Result.KdHelp.KeUserCallbackDispatcher := Value.KdHelp.KeUserCallbackDispatcher;
    Result.KdHelp.SystemRangeStart := Value.KdHelp.SystemRangeStart;
    Result.KdHelp.KiUserExceptionDispatcher := Value.KdHelp.KiUserExceptionDispatcher;
    Result.KdHelp.StackBase := Value.KdHelp.StackBase;
    Result.KdHelp.StackLimit := Value.KdHelp.StackLimit;
  end;

var
  {$IFDEF WIN32}
  StackFrame: TStackFrame;
  {$ELSE}
  StackFrame: TStackFrame64;
  {$ENDIF}
  ThreadContext: PContext;
  MachineType: DWORD;
  ThreadShackEntry: TThreadStackEntry;
begin
  // ThreadContext ������ ���� ��������, ������� ���������� VirtualAlloc
  // ������� ������������� ������� ������ ���������� �� ������ ��������
  // � ��������� ������ ������� ERROR_NOACCESS (998)
  ThreadContext := VirtualAlloc(nil, SizeOf(TContext), MEM_COMMIT, PAGE_READWRITE);
  try
    ThreadContext^.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(hThread, ThreadContext^) then
      Exit;

    ZeroMemory(@StackFrame, SizeOf(TStackFrame));
    StackFrame.AddrPC.Mode := AddrModeFlat;
    StackFrame.AddrStack.Mode := AddrModeFlat;
    StackFrame.AddrFrame.Mode := AddrModeFlat;
    {$IFDEF WIN32}
    StackFrame.AddrPC.Offset := ThreadContext.Eip;
    StackFrame.AddrStack.Offset := ThreadContext.Esp;
    StackFrame.AddrFrame.Offset := ThreadContext.Ebp;
    MachineType := IMAGE_FILE_MACHINE_I386;
    {$ELSE}
    StackFrame.AddrPC.Offset := ThreadContext.Rip;
    StackFrame.AddrStack.Offset := ThreadContext.Rsp;
    StackFrame.AddrFrame.Offset := ThreadContext.Rbp;
    MachineType := IMAGE_FILE_MACHINE_AMD64;
    {$ENDIF}

    while True do
    begin

      {$IFDEF WIN32}
      if not StackWalk(MachineType, hProcess, hThread, @StackFrame,
        ThreadContext, nil, nil, nil, nil) then
        Break;
      {$ELSE}
      if not StackWalk64(MachineType, hProcess, hThread, StackFrame,
        ThreadContext, nil, nil, nil, nil) then
        Break;
      {$ENDIF}

      if StackFrame.AddrPC.Offset <= 0 then Break;

      ThreadShackEntry.ThreadID := ID;
      {$IFDEF WIN32}
      ThreadShackEntry.Data := ConvertStackFrameToStackFrame64(StackFrame);
      {$ELSE}
      ThreadShackEntry.Data := StackFrame;
      {$ENDIF}
      ThreadShackEntry.Wow64 := False;
      ThreadStackEntries.Add(ThreadShackEntry);
    end;

  finally
    VirtualFree(ThreadContext, SizeOf(TContext), MEM_FREE);
  end;
end;

procedure TThreads.GetThreadSEHFrames(hProcess: THandle; InitialAddr: Pointer;
  ID: Integer);
type
  EXCEPTION_REGISTRATION = record
    prev, handler: Pointer;
  end;
var
  ER: EXCEPTION_REGISTRATION;
  lpNumberOfBytesRead: NativeUInt;
  SEHEntry: TSEHEntry;
begin
  while ReadProcessMemory(hProcess, InitialAddr, @ER,
    SizeOf(EXCEPTION_REGISTRATION), lpNumberOfBytesRead) do
  begin
    SEHEntry.ThreadID := ID;
    SEHEntry.Address := InitialAddr;
    SEHEntry.Previous := ER.prev;
    SEHEntry.Handler := ER.handler;
    SEHEntry.Wow64 := False;
    SEHEntries.Add(SEHEntry);
    InitialAddr := ER.prev;
    if DWORD(InitialAddr) <= 0 then Break;
  end;
end;

procedure TThreads.Update(PID: Cardinal; hProcess: THandle);
const
  THREAD_GET_CONTEXT = 8;
  THREAD_SUSPEND_RESUME = 2;
  THREAD_QUERY_INFORMATION = $40;
  ThreadBasicInformation = 0;
  ThreadQuerySetWin32StartAddress = 9;
var
  hSnap, hThread: THandle;
  ThreadEntry: TThreadEntry32;
  TBI: TThreadBasicInformation;
  TIB: NT_TIB;
  lpNumberOfBytesRead: NativeUInt;
  ThreadStartAddress: Pointer;
begin

  // ������ ������ ����� � �������
  hSnap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, PID);
  if hSnap <> INVALID_HANDLE_VALUE then
  try
    ThreadEntry.dwSize := SizeOf(TThreadEntry32);
    if Thread32First(hSnap, ThreadEntry) then
    repeat
      if ThreadEntry.th32OwnerProcessID <> PID then Continue;

      // ��������� ����
      hThread := OpenThread(THREAD_GET_CONTEXT or
        THREAD_SUSPEND_RESUME or THREAD_QUERY_INFORMATION,
        False, ThreadEntry.th32ThreadID);
      if hThread <> 0 then
      try
        // �������� ����� ThreadProc()
        if NtQueryInformationThread(hThread, ThreadQuerySetWin32StartAddress,
          @ThreadStartAddress, SizeOf(ThreadStartAddress), nil) = STATUS_SUCCESS then
          Add(hProcess, tiThreadProc, ThreadStartAddress, ThreadEntry.th32ThreadID);
        // �������� ���������� �� ����
        if NtQueryInformationThread(hThread, ThreadBasicInformation, @TBI,
          SizeOf(TThreadBasicInformation), nil) = STATUS_SUCCESS then
        begin
          // ������ �� ���������� ��������� ������������
          // TIB (Thread Information Block) �������� ����
          if not ReadProcessMemory(hProcess,
            TBI.TebBaseAddress, @TIB, SizeOf(NT_TIB),
            lpNumberOfBytesRead) then Exit;
          // ��������� � ������ ����� �����
          Add(hProcess, tiStackBase, TIB.StackBase, ThreadEntry.th32ThreadID);
          Add(hProcess, tiStackLimit, TIB.StackLimit, ThreadEntry.th32ThreadID);
          Add(hProcess, tiTEB, TIB.Self, ThreadEntry.th32ThreadID);
        end;
        // �������� ���� ����
        GetThreadCallStack(hProcess, hThread, ThreadEntry.th32ThreadID);
        {$IFDEF WIN32}
        // �������� ������ SEH �������
        GetThreadSEHFrames(hProcess, TIB.ExceptionList, ThreadEntry.th32ThreadID);
        {$ENDIF}
      finally
        CloseHandle(hThread);
      end;
    until not Thread32Next(hSnap, ThreadEntry);
  finally
     CloseHandle(hSnap);
  end;
end;

end.
