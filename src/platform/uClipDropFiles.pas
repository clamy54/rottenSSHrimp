{ Liste de fichiers du presse-papiers local: CF_HDROP sous Windows,
  public.file-url sous macOS, text/uri-list (+ x-special/gnome-copied-files)
  sous X11. Meme contrat partout: lire rend TOUT ou rien, ecrire remplace.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipDropFiles;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}{$modeswitch objectivec1}{$ENDIF}

interface

uses
  SysUtils;

// False = presse-papiers verrouille par un autre, a retenter. Vide n'est pas False.
function ClipReadHdrop(out APaths: TStringArray): Boolean;

// False = fichiers non poses. Le presse-papiers a pu etre vide au passage,
// comme apres n'importe quelle copie ratee.
function ClipWriteHdrop(const APaths: TStringArray): Boolean;

// Change a chaque ecriture, par qui que ce soit. Emule par empreinte sous X11.
function ClipSequence: LongWord;

// Portables (testables sous Windows): le format uri-list de X11.
// AGnome ajoute l'en-tete « copy » de x-special/gnome-copied-files.
function BuildUriList(const APaths: TStringArray; AGnome: Boolean): string;
// Tout ou rien: une seule entree non file:// et la liste entiere est refusee.
function ParseUriList(const AText: string; out APaths: TStringArray): Boolean;

implementation

{$IFNDEF WINDOWS}
uses
  {$IFDEF DARWIN}CocoaAll{$ELSE}Classes, LCLType, Clipbrd{$ENDIF};
{$ENDIF}

// hors des non-reserves de la RFC 3986; '/' reste un separateur
function PctEncodePath(const APath: string): string;
const
  KEEP = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'];
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(APath) do
    if APath[i] in KEEP then
      Result := Result + APath[i]
    else
      Result := Result + '%' + IntToHex(Ord(APath[i]), 2);
end;

function PctDecode(const S: string; out AOut: string): Boolean;
var
  i, v: Integer;
begin
  Result := False;
  AOut := '';
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '%' then
    begin
      if i + 2 > Length(S) then Exit;
      v := StrToIntDef('$' + Copy(S, i + 1, 2), -1);
      // %00 tronquerait le chemin chez tous les consommateurs de PChar
      if v <= 0 then Exit;
      AOut := AOut + Chr(v);
      Inc(i, 3);
    end
    else
    begin
      if S[i] = #0 then Exit;
      AOut := AOut + S[i];
      Inc(i);
    end;
  end;
  Result := True;
end;

function BuildUriList(const APaths: TStringArray; AGnome: Boolean): string;
var
  i: Integer;
  sep: string;
begin
  // gnome-copied-files veut du LF; text/uri-list, du CRLF (RFC 2483)
  if AGnome then sep := #10 else sep := #13#10;
  Result := '';
  if AGnome then
    Result := 'copy';
  for i := 0 to High(APaths) do
  begin
    if Result <> '' then
      Result := Result + sep;
    Result := Result + 'file://' + PctEncodePath(APaths[i]);
  end;
  if not AGnome then
    Result := Result + #13#10;
end;

function ParseUriList(const AText: string; out APaths: TStringArray): Boolean;
var
  lines: TStringArray;
  n, i: Integer;
  line, rest, path: string;
  p: Integer;
begin
  Result := False;
  APaths := nil;
  lines := AText.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  n := 0;
  SetLength(APaths, Length(lines));
  for i := 0 to High(lines) do
  begin
    line := Trim(lines[i]);
    if (line = '') or (line[1] = '#') then
      Continue;
    // en-tete gnome-copied-files; « cut » est traite comme une copie
    if (i = 0) and ((line = 'copy') or (line = 'cut')) then
      Continue;
    if not line.StartsWith('file://') then
      Exit;
    rest := Copy(line, 8, MaxInt);
    // autorite: vide ou localhost, rien d'autre
    p := Pos('/', rest);
    if p = 0 then Exit;
    if (p > 1) and (Copy(rest, 1, p - 1) <> 'localhost') then Exit;
    if not PctDecode(Copy(rest, p, MaxInt), path) then Exit;
    if (path = '') or (path[1] <> '/') then Exit;
    APaths[n] := path;
    Inc(n);
  end;
  SetLength(APaths, n);
  Result := n > 0;
end;

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
  if not IsClipboardFormatAvailable(CF_HDROP_) then
    Exit(True);
  if not OpenClipboard(0) then
    Exit;
  try
    h := GetClipboardData(CF_HDROP_);
    if h = 0 then
      Exit;
    // ENTIERE, jamais tronquee: c'est l'annonce qui refuse, avec un motif.
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

  // Sans « Preferred DropEffect » = copie, certains collages DEPLACENT et
  // l'Explorateur efface nos temporaires sources.
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
{$IFDEF DARWIN}

const
  FILE_URL_TYPE = 'public.file-url';

function ClipSequence: LongWord;
begin
  Result := LongWord(NSPasteboard.generalPasteboard.changeCount);
end;

// Un pasteboard item par fichier, comme le Finder. Tout ou rien: un item
// sans file-url (texte, image) et la reponse est « pas de fichiers ».
function ClipReadHdrop(out APaths: TStringArray): Boolean;
var
  items: NSArray;
  it: NSPasteboardItem;
  s: NSString;
  u: NSURL;
  i: Integer;
begin
  APaths := nil;
  Result := True;
  items := NSPasteboard.generalPasteboard.pasteboardItems;
  if (items = nil) or (items.count = 0) then
    Exit;
  SetLength(APaths, items.count);
  for i := 0 to Integer(items.count) - 1 do
  begin
    it := NSPasteboardItem(items.objectAtIndex(i));
    s := it.stringForType(NSString.stringWithUTF8String(FILE_URL_TYPE));
    if s = nil then
    begin
      APaths := nil;
      Exit;
    end;
    u := NSURL.URLWithString(s);
    if (u = nil) or (not u.isFileURL) or (u.path = nil) then
    begin
      APaths := nil;
      Exit;
    end;
    APaths[i] := AnsiString(u.path.UTF8String);
  end;
end;

function ClipWriteHdrop(const APaths: TStringArray): Boolean;
var
  arr: NSMutableArray;
  it: NSPasteboardItem;
  u: NSURL;
  i: Integer;
begin
  Result := False;
  if Length(APaths) = 0 then
    Exit;
  arr := NSMutableArray.arrayWithCapacity(Length(APaths));
  for i := 0 to High(APaths) do
  begin
    u := NSURL.fileURLWithPath(NSString.stringWithUTF8String(
      PAnsiChar(APaths[i])));
    if u = nil then
      Exit;
    it := NSPasteboardItem(NSPasteboardItem.alloc).init;
    it.setString_forType(u.absoluteString,
      NSString.stringWithUTF8String(FILE_URL_TYPE));
    arr.addObject(it);
    it.release;   // le tableau le retient
  end;
  NSPasteboard.generalPasteboard.clearContents;
  Result := NSPasteboard.generalPasteboard.writeObjects(arr);
end;

{$ELSE}
// X11 via la LCL. Nautilus lit x-special/gnome-copied-files, le reste
// (Dolphin, Thunar, pcmanfm) se contente de text/uri-list.

var
  GUriFmt: TClipboardFormat = 0;
  GGnomeFmt: TClipboardFormat = 0;

procedure NeedFormats;
begin
  if GUriFmt = 0 then
    GUriFmt := RegisterClipboardFormat('text/uri-list');
  if GGnomeFmt = 0 then
    GGnomeFmt := RegisterClipboardFormat('x-special/gnome-copied-files');
end;

function ReadFormat(AFmt: TClipboardFormat; out AText: string): Boolean;
var
  ms: TMemoryStream;
begin
  Result := False;
  AText := '';
  ms := TMemoryStream.Create;
  try
    if not Clipboard.GetFormat(AFmt, ms) then
      Exit;
    SetLength(AText, ms.Size);
    if ms.Size > 0 then
      Move(ms.Memory^, AText[1], ms.Size);
    Result := True;
  finally
    ms.Free;
  end;
end;

function ClipReadHdrop(out APaths: TStringArray): Boolean;
var
  s: string;
begin
  APaths := nil;
  Result := True;
  try
    NeedFormats;
    if Clipboard.HasFormat(GGnomeFmt) and ReadFormat(GGnomeFmt, s) and
       ParseUriList(s, APaths) then
      Exit;
    APaths := nil;
    // uri-list seul: un lien http copie dans un navigateur y passe aussi,
    // d'ou le tout-ou-rien de ParseUriList
    if Clipboard.HasFormat(GUriFmt) and ReadFormat(GUriFmt, s) then
      if not ParseUriList(s, APaths) then
        APaths := nil;
  except
    APaths := nil;
  end;
end;

function ClipWriteHdrop(const APaths: TStringArray): Boolean;
var
  gnome, uris: string;
  msG, msU: TMemoryStream;
begin
  Result := False;
  if Length(APaths) = 0 then
    Exit;
  NeedFormats;
  gnome := BuildUriList(APaths, True);
  uris := BuildUriList(APaths, False);
  msG := TMemoryStream.Create;
  msU := TMemoryStream.Create;
  try
    msG.WriteBuffer(gnome[1], Length(gnome));
    msU.WriteBuffer(uris[1], Length(uris));
    msG.Position := 0;
    msU.Position := 0;
    // Open/Close: une seule prise de possession, les deux formats ou aucun.
    // Sans, chaque AddFormat publie seul et Nautilus voit un etat a moitie.
    try
      Clipboard.Open;
      try
        Clipboard.Clear;   // le cache LCL, pas X11
        Result := Clipboard.AddFormat(GGnomeFmt, msG) and
          Clipboard.AddFormat(GUriFmt, msU);
        if not Result then
          Clipboard.Clear;   // un format seul ne part pas
      finally
        Clipboard.Close;
      end;
      // Close avale l'echec de possession: il vide alors le cache
      Result := Result and Clipboard.HasFormat(GGnomeFmt) and
        Clipboard.HasFormat(GUriFmt);
    except
      Result := False;
    end;
  finally
    msG.Free;
    msU.Free;
  end;
end;

// X11 n'a pas de compteur: empreinte du contenu (texte + uris). Deux etats
// differents peuvent la partager, au pire un collage en attente est pose.
function ClipSequence: LongWord;
var
  h: QWord;
  s, t: string;

  procedure Mix(const A: string);
  var
    i: Integer;
  begin
    for i := 1 to Length(A) do
      h := (h xor QWord(Byte(A[i]))) * QWord($100000001b3);
  end;

begin
  h := QWord($cbf29ce484222325);
  try
    NeedFormats;
    t := Clipboard.AsText;
    s := '';
    if Clipboard.HasFormat(GUriFmt) then
      ReadFormat(GUriFmt, s);
    Mix(t);
    Mix(#1);
    Mix(s);
  except
    Exit(0);
  end;
  Result := LongWord(h) xor LongWord(h shr 32);
end;

{$ENDIF}
{$ENDIF}

end.
