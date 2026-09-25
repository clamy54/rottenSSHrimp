{ CF_HDROP, lu et ecrit par l'API Windows: la liste de fichiers du
  presse-papiers local, telle que l'Explorateur la pose et la colle. Les
  autres plateformes compilent des reponses vides -- le copier-coller de
  fichiers RDP est un pont Windows<->Windows.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipDropFiles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

// True avec la liste (vide s'il n'y a pas de fichiers); False = presse-papiers
// verrouille par un autre programme, a retenter.
function ClipReadHdrop(out APaths: TStringArray): Boolean;

// Pose APaths en CF_HDROP avec « Preferred DropEffect » = copie. False =
// rien n'a ete change.
function ClipWriteHdrop(const APaths: TStringArray): Boolean;

// Numero de sequence du presse-papiers systeme: il change a CHAQUE ecriture,
// par qui que ce soit. Zero la ou la plateforme ne le donne pas.
function ClipSequence: LongWord;

implementation

{$IFDEF WINDOWS}

const
  CF_HDROP_ = 15;
  GMEM_MOVEABLE_ = 2;
  DROPEFFECT_COPY_ = 1;

type
  // DROPFILES de shellapi.h: 20 octets, alignement naturel.
  TDropFiles_ = record
    pFiles: LongWord;
    ptX, ptY: LongInt;
    fNC: LongBool;
    fWide: LongBool;
  end;
  PDropFiles_ = ^TDropFiles_;

function IsClipboardFormatAvailable(AFormat: LongWord): LongBool; stdcall;
  external 'user32.dll';
function OpenClipboard(AOwner: PtrUInt): LongBool; stdcall;
  external 'user32.dll';
function CloseClipboard: LongBool; stdcall; external 'user32.dll';
function EmptyClipboard: LongBool; stdcall; external 'user32.dll';
function GetClipboardData(AFormat: LongWord): PtrUInt; stdcall;
  external 'user32.dll';
function SetClipboardData(AFormat: LongWord; AMem: PtrUInt): PtrUInt; stdcall;
  external 'user32.dll';
function RegisterClipboardFormatW(AName: PWideChar): LongWord; stdcall;
  external 'user32.dll';
function DragQueryFileW(ADrop: PtrUInt; AFile: LongWord; ABuf: PWideChar;
  ACch: LongWord): LongWord; stdcall; external 'shell32.dll';
function GlobalAlloc(AFlags: LongWord; ABytes: PtrUInt): PtrUInt; stdcall;
  external 'kernel32.dll';
function GlobalLock(AMem: PtrUInt): Pointer; stdcall; external 'kernel32.dll';
function GlobalUnlock(AMem: PtrUInt): LongBool; stdcall;
  external 'kernel32.dll';
function GlobalFree(AMem: PtrUInt): PtrUInt; stdcall; external 'kernel32.dll';
function GetClipboardSequenceNumber: LongWord; stdcall;
  external 'user32.dll';

function ClipSequence: LongWord;
begin
  Result := GetClipboardSequenceNumber;
end;

function ClipReadHdrop(out APaths: TStringArray): Boolean;
var
  h: PtrUInt;
  n, i, len: LongWord;
  buf: UnicodeString;
begin
  APaths := nil;
  Result := False;
  // Pas de fichiers: une lecture SAINE d'une liste vide, pas un echec.
  if not IsClipboardFormatAvailable(CF_HDROP_) then
    Exit(True);
  if not OpenClipboard(0) then
    Exit;
  try
    h := GetClipboardData(CF_HDROP_);
    if h = 0 then
      Exit;
    // La liste part ENTIERE: tronquer ici enverrait au serveur une selection
    // qui n'est pas celle copiee. C'est l'annonce qui refuse, avec un motif.
    n := DragQueryFileW(h, $FFFFFFFF, nil, 0);
    SetLength(APaths, n);
    for i := 0 to n - 1 do
    begin
      len := DragQueryFileW(h, i, nil, 0);
      if len = 0 then
        Exit;
      buf := '';
      SetLength(buf, len);
      if DragQueryFileW(h, i, PWideChar(buf), len + 1) = 0 then
        Exit;
      APaths[i] := UTF8Encode(buf);
    end;
    Result := True;
  finally
    CloseClipboard;
    if not Result then
      APaths := nil;
  end;
end;

function ClipWriteHdrop(const APaths: TStringArray): Boolean;
var
  wides: array of UnicodeString;
  totalW: PtrUInt;
  hDrop, hEff: PtrUInt;
  p: PByte;
  pw: PWideChar;
  df: PDropFiles_;
  fmtEff: LongWord;
  i: Integer;
begin
  Result := False;
  if Length(APaths) = 0 then
    Exit;
  SetLength(wides{%H-}, Length(APaths));
  totalW := 1;   // le second NUL de la fin de liste
  for i := 0 to High(APaths) do
  begin
    wides[i] := UTF8Decode(APaths[i]);
    Inc(totalW, PtrUInt(Length(wides[i])) + 1);
  end;
  hDrop := GlobalAlloc(GMEM_MOVEABLE_, SizeOf(TDropFiles_) + totalW * 2);
  if hDrop = 0 then
    Exit;
  p := GlobalLock(hDrop);
  if p = nil then
  begin
    GlobalFree(hDrop);
    Exit;
  end;
  df := PDropFiles_(p);
  FillChar(df^, SizeOf(TDropFiles_), 0);
  df^.pFiles := SizeOf(TDropFiles_);
  df^.fWide := True;
  pw := PWideChar(p + SizeOf(TDropFiles_));
  for i := 0 to High(wides) do
  begin
    if Length(wides[i]) > 0 then
      Move(wides[i][1], pw^, Length(wides[i]) * 2);
    Inc(pw, Length(wides[i]));
    pw^ := #0;
    Inc(pw);
  end;
  pw^ := #0;
  GlobalUnlock(hDrop);

  // « Preferred DropEffect » = copie: sans lui certains collages proposent un
  // DEPLACEMENT, et l'Explorateur effacerait nos temporaires sources.
  hEff := GlobalAlloc(GMEM_MOVEABLE_, 4);
  if hEff <> 0 then
  begin
    p := GlobalLock(hEff);
    if p = nil then
    begin
      GlobalFree(hEff);
      hEff := 0;
    end
    else
    begin
      PLongWord(p)^ := DROPEFFECT_COPY_;
      GlobalUnlock(hEff);
    end;
  end;

  if OpenClipboard(0) then
  try
    if EmptyClipboard then
    begin
      Result := SetClipboardData(CF_HDROP_, hDrop) <> 0;
      if Result then
      begin
        hDrop := 0;   // le systeme en a pris possession
        if hEff <> 0 then
        begin
          fmtEff := RegisterClipboardFormatW('Preferred DropEffect');
          if (fmtEff <> 0) and (SetClipboardData(fmtEff, hEff) <> 0) then
            hEff := 0;
        end;
      end;
    end;
  finally
    CloseClipboard;
  end;
  if hDrop <> 0 then
    GlobalFree(hDrop);
  if hEff <> 0 then
    GlobalFree(hEff);
end;

{$ELSE}

function ClipReadHdrop(out APaths: TStringArray): Boolean;
begin
  APaths := nil;
  Result := True;
end;

function ClipWriteHdrop(const APaths: TStringArray): Boolean;
begin
  Result := False;
end;

function ClipSequence: LongWord;
begin
  Result := 0;
end;

{$ENDIF}

end.
