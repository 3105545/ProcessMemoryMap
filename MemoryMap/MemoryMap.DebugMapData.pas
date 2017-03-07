////////////////////////////////////////////////////////////////////////////////
//
//  ****************************************************************************
//  * Project   : MemoryMap
//  * Unit Name : MemoryMap.DebugMapData.pas
//  * Purpose   : ����� ��� ������ � ���������� MAP ������.
//  * Author    : ��������� (Rouse_) ������
//  * Copyright : � Fangorn Wizards Lab 1998 - 2017.
//  * Version   : 1.0.1
//  * Home Page : http://rouse.drkb.ru
//  * Home Blog : http://alexander-bagel.blogspot.ru
//  ****************************************************************************
//  * Stable Release : http://rouse.drkb.ru/winapi.php#pmm2
//  * Latest Source  : https://github.com/AlexanderBagel/ProcessMemoryMap
//  ****************************************************************************
//

unit MemoryMap.DebugMapData;

interface

uses
  Winapi.Windows,
  System.Classes,
  Generics.Collections,
  Generics.Defaults,
  System.SysUtils;

type
  TDebugMapItem = record
    Address, EndAddress: NativeUInt;
    ModuleName,
    FunctionName: string;
  end;

  TDebugMap = class
  private type
    TSectionData = record
      Index: Integer;
      StartAddr: DWORD;
      Length: DWORD;
    end;
  private
    FItems: TList<TDebugMapItem>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Init(BaseAddress: ULONG_PTR; const ModulePath: string);
    function GetDescriptionAtAddr(Address: ULONG_PTR): string;
    function GetDescriptionAtAddrWithOffset(Address: ULONG_PTR): string;
    procedure GetExportFuncList(const ModuleName: string; Value: TStringList);
  end;

implementation

uses
  MemoryMap.PEImage;

{ TDebugMap }

procedure TDebugMap.Clear;
begin
  FItems.Clear;
end;

constructor TDebugMap.Create;
begin
  FItems := TList<TDebugMapItem>.Create(
   TComparer<TDebugMapItem>.Construct(
     function (const A, B: TDebugMapItem): Integer
     begin
       Result := Integer(A.Address) - Integer(B.Address);
     end)
   );
end;

destructor TDebugMap.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TDebugMap.GetDescriptionAtAddr(Address: ULONG_PTR): string;
var
  I: Integer;
  Item: TDebugMapItem;
begin
  Result := '';
  Item.Address := Address;
  if FItems.BinarySearch(Item, I) then
    if I >= 0 then
      Result := FItems.List[I].ModuleName + '!' + FItems.List[I].FunctionName;
end;

function TDebugMap.GetDescriptionAtAddrWithOffset(Address: ULONG_PTR): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FItems.Count - 1 do
    if FItems.List[I].Address <= Address then
      if FItems.List[I].EndAddress > Address then
      begin
        if FItems.List[I].Address = Address then
          Result := FItems.List[I].ModuleName + '!' + FItems.List[I].FunctionName
        else
          Result := FItems.List[I].ModuleName + '!' + FItems.List[I].FunctionName +
            ' + 0x' + IntToHex(Address - FItems.List[I].Address, 1);
      end;
end;

procedure TDebugMap.GetExportFuncList(const ModuleName: string;
  Value: TStringList);
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if FItems[I].ModuleName = ModuleName then
      Value.AddObject(FItems[I].FunctionName, Pointer(FItems[I].Address));
end;

procedure TDebugMap.Init(BaseAddress: ULONG_PTR; const ModulePath: string);
var
  PEImage: TPEImage;
  MapFile: TStringList;
  SectionDataList: TList<TSectionData>;
  I, A, Count, StartPosition, SpacePos, SectionIndex: Integer;
  Line, SectionName, SectionClass: string;
  Section: TSectionData;
  FoundTable: Boolean;
  SectionAddress: DWORD;
  DebugMapItem: TDebugMapItem;
begin
  StartPosition := FItems.Count;
  try
    MapFile := TStringList.Create;
    try
      MapFile.LoadFromFile(ChangeFileExt(ModulePath, '.map'));
      DebugMapItem.ModuleName := ExtractFileName(ModulePath);
      SectionDataList := TList<TSectionData>.Create;
      try
        PEImage := TPEImage.Create(0, False);
        try
          PEImage.GetInfoFromImage(ModulePath, nil, 0);

          I := 0;
          Count := MapFile.Count;

          // ���� ������ ������� ������
          while Copy(Trim(MapFile[I]), 1, 5) <> 'Start' do
          begin
            Inc(I);
            if I = Count then Exit;
          end;

          // �������� ����� ������ � �� ���
          Inc(I);
          if I = Count then Exit;
          Line := Trim(MapFile[I]);
          while Line <> '' do
          begin
            Section.Index := StrToInt(Copy(Line, 1, 4));
            Delete(Line, 1, 24);
            Line := TrimLeft(Line);
            SpacePos := Pos(' ', Line);
            if SpacePos = 0 then Continue;
            SectionName := Copy(Line, 1, SpacePos - 1);
            Delete(Line, 1, SpacePos);

            // � ������ ������� ������ � �� ����� ��� ������ ���������� �� ����� �� ������
            // ������� ����� ������ ���������� ������ �������� �� ���� ������
            SectionClass := TrimLeft(Line);

            // ������� ������������� (MS VC++ Debug MAP)
            SpacePos := Pos('$', SectionName);
            if SpacePos > 0 then
              SectionName := Copy(SectionName, 1, SpacePos - 1);

            // ���� ������ �������� ���, ������� �� � ������
            for A := 0 to PEImage.Sections.Count - 1 do
              if (PEImage.Sections[A].Caption = ShortString(SectionName)) or
                (PEImage.Sections[A].Caption = ShortString(SectionClass)) then
              begin
                if PEImage.Sections[A].IsCode then
                begin
                  Section.StartAddr := PEImage.Sections[A].Address + BaseAddress;
                  Section.Length := PEImage.Sections[A].Size;
                  SectionDataList.Add(Section);
                end;
                Break;
              end;

            Inc(I);
            if I = Count then Exit;
            Line := Trim(MapFile[I]);
          end;
        finally
          PEImage.Free;
        end;

        // ���� ������ ������� "Publics by Value"
        FoundTable := False;
        while not FoundTable do
        begin
          Inc(I);
          if I = Count then Exit;
          Line := Trim(MapFile[I]);
          while Copy(Line, 1, 7) <> 'Address' do
          begin
            Inc(I);
            if I = Count then Exit;
            Line := Trim(MapFile[I]);
          end;
          Delete(Line, 1, 8);
          FoundTable := Copy(TrimLeft(Line), 1, 16) = 'Publics by Value';
        end;

        // ������ ������� "Publics by Value"
        Inc(I, 2);
        if I >= Count then Exit;
        Line := Trim(MapFile[I]);
        while Line <> '' do
        begin
          SectionIndex := StrToInt(Copy(Line, 1, 4));
          if SectionIndex <> 1 then
          begin
            Inc(I);
            if I = Count then Exit;
            Line := Trim(MapFile[I]);
            Continue;
          end;
          SectionAddress := $FFFFFFFF;
          for A := 0 to SectionDataList.Count - 1 do
            if SectionDataList[A].Index = SectionIndex then
            begin
              SectionAddress := SectionDataList[A].StartAddr;
              DebugMapItem.EndAddress := SectionAddress + SectionDataList[A].Length;
              Break;
            end;
          if SectionAddress = $FFFFFFFF then Continue;
          Delete(Line, 1, 5);
          DebugMapItem.Address := SectionAddress + NativeUInt(StrToInt('$' + Copy(Line, 1, 8)));
          Delete(Line, 1, 9);
          Line := TrimLeft(Line);
          SpacePos := Pos(' ', Line);
          if SpacePos = 0 then
            DebugMapItem.FunctionName := Line
          else
            DebugMapItem.FunctionName := Copy(Line, 1, SpacePos - 1);
          FItems.Add(DebugMapItem);
          Inc(I);
          if I = Count then Exit;
          Line := Trim(MapFile[I]);
        end;

      finally
        SectionDataList.Free;
      end;
    finally
      MapFile.Free;
    end;

    // ��������� ���������� ����� �������
    for I := FItems.Count - 1 downto StartPosition + 1 do
      FItems.List[I - 1].EndAddress := FItems.List[I].Address;

    FItems.Sort;
  except
    // ���� �� ������ ���������� - ���������� ��� �� ������� ������
    for I := FItems.Count - 1 downto StartPosition do
      FItems.Delete(I);
  end;
end;

end.
