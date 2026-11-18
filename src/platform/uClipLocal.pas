{ Presse-papiers LOCAL en plusieurs formats, par la LCL. Thread UI seulement.
  Les noms changent d'un systeme a l'autre, le contenu non:
    Windows   CF_UNICODETEXT, "HTML Format", "Rich Text Format", CF_DIB, "PNG"
    Linux     text/plain,     text/html,     text/rtf,           image/png
    macOS     public.utf8,    public.html,   public.rtf,         public.png

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipLocal;

{$mode objfpc}{$H+}

interface

uses
  uClipSnapshot;

// False: presse-papiers verrouille, on retentera. Vide = reference valide.
function ClipReadSnapshot(out S: TClipSnapshot): Boolean;
// Tous les formats en une seule prise de possession, ou aucun.
function ClipWriteSnapshot(const S: TClipSnapshot): Boolean;

implementation

uses
  Classes, SysUtils, LCLType, Clipbrd;

type
  // Refuse d'enfler au-dela du plafond: la LCL ecrit tout d'un bloc, le bloc
  // trop gros leve et on n'en garde rien.
  ECapped = class(Exception);
  TCappedStream = class(TMemoryStream)
  private
    FMax: Int64;
  public
    constructor Create(AMax: Int64);
    function Write(const Buffer; Count: LongInt): LongInt; override;
    procedure SetSize({$ifdef CPU64}const NewSize: Int64{$else}NewSize: LongInt{$endif}); override;
  end;

const
  // 2 M unites UTF-16 cote transport, jusqu'a 3 octets UTF-8 chacune
  CLIP_TEXT_MAX_BYTES = 3 * 2 * 1024 * 1024;

var
  GHtml, GRtf, GPng, GBmp, GDib: TClipboardFormat;
  GReady: Boolean = False;

constructor TCappedStream.Create(AMax: Int64);
begin
  inherited Create;
  FMax := AMax;
end;

function TCappedStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  if Position + Count > FMax then
    raise ECapped.Create('clipboard item too large');
  Result := inherited Write(Buffer, Count);
end;

// la LCL preetire parfois avant d'ecrire
procedure TCappedStream.SetSize({$ifdef CPU64}const NewSize: Int64{$else}NewSize: LongInt{$endif});
begin
  if NewSize > FMax then
    raise ECapped.Create('clipboard item too large');
  inherited SetSize(NewSize);
end;

{$IFDEF WINDOWS}
function OpenClipboard(AOwner: PtrUInt): LongBool; stdcall; external 'user32.dll';
function CloseClipboard: LongBool; stdcall; external 'user32.dll';
function GetClipboardData(AFormat: LongWord): PtrUInt; stdcall; external 'user32.dll';
function GlobalSize(AMem: PtrUInt): PtrUInt; stdcall; external 'kernel32.dll';

// Avant que la LCL ne copie, et pour le texte ne convertisse, le tout.
// Presse-papiers occupe: on ne sait pas, la limite du flux reste la.
function NativeTooBig(AFmt: TClipboardFormat; AMax: Int64): Boolean;
var
  h: PtrUInt;
begin
  Result := False;
  if not OpenClipboard(0) then
    Exit;
  try
    h := GetClipboardData(LongWord(AFmt));
    Result := (h <> 0) and (Int64(GlobalSize(h)) > AMax);
  finally
    CloseClipboard;
  end;
end;
{$ENDIF}

procedure NeedFormats;
begin
  if GReady then Exit;
  {$IF defined(WINDOWS)}
  GHtml := RegisterClipboardFormat('HTML Format');
  GRtf := RegisterClipboardFormat('Rich Text Format');
  GPng := RegisterClipboardFormat('PNG');
  GDib := 8;   // CF_DIB; Windows le synthetise depuis n'importe quel bitmap
  GBmp := 0;
  {$ELSEIF defined(DARWIN)}
  GHtml := RegisterClipboardFormat('public.html');
  GRtf := RegisterClipboardFormat('public.rtf');
  GPng := RegisterClipboardFormat('image/png');
  GDib := 0;
  // la LCL convertit ici n'importe quelle image, TIFF des captures compris
  GBmp := RegisterClipboardFormat('image/bmp');
  {$ELSE}
  GHtml := RegisterClipboardFormat('text/html');
  GRtf := RegisterClipboardFormat('text/rtf');
  GPng := RegisterClipboardFormat('image/png');
  GDib := 0;
  GBmp := RegisterClipboardFormat('image/bmp');
  {$ENDIF}
  GReady := True;
end;

// Trop gros = absent. Le contenu local a le droit d'exister, pas de nous ruiner.
function ReadFmt(AFmt: TClipboardFormat; AMax: Int64; out AData: RawByteString): Boolean;
var
  ms: TMemoryStream;
begin
  Result := False;
  AData := '';
  if (AFmt = 0) or not Clipboard.HasFormat(AFmt) then
    Exit;
  {$IFDEF WINDOWS}
  // texte: UTF-16 cote Windows, deux octets pour au plus trois en UTF-8
  if (AFmt = CF_TEXT) and NativeTooBig(AFmt, AMax * 2) then
    Exit;
  if (AFmt <> CF_TEXT) and NativeTooBig(AFmt, AMax) then
    Exit;
  {$ENDIF}
  ms := TCappedStream.Create(AMax);
  try
    try
      if not Clipboard.GetFormat(AFmt, ms) or (ms.Size = 0) then
        Exit;
    except
      on ECapped do
        Exit;
    end;
    SetLength(AData, ms.Size);
    Move(ms.Memory^, AData[1], ms.Size);
    Result := True;
  finally
    ms.Free;
  end;
end;

procedure ReadImage(var S: TClipSnapshot);
var
  raw: RawByteString;
  img: TClipImage;
  why: string;
begin
  if ReadFmt(GPng, CLIP_IMAGE_MAX_BYTES, raw) then
    S.Png := raw
  else if ReadFmt(GDib, CLIP_IMAGE_MAX_BYTES, raw) then
    S.Dib := raw
  // BMP de la LCL: on le ramene a un DIB propre, l'en-tete fichier en moins
  else if ReadFmt(GBmp, CLIP_IMAGE_MAX_BYTES, raw) and
          BmpFileDecode(raw, img, why) then
    S.Dib := DibEncode(img);
end;

function ClipReadSnapshot(out S: TClipSnapshot): Boolean;
var
  raw: RawByteString;
begin
  S := Default(TClipSnapshot);
  try
    NeedFormats;
    if ReadFmt(CF_TEXT, CLIP_TEXT_MAX_BYTES, raw) then
    begin
      // texte Windows et GTK: parfois NUL-termine, parfois pas
      if Pos(#0, raw) > 0 then
        SetLength(raw, Pos(#0, raw) - 1);
      S.Text := UTF8Decode(raw);
    end;
    if ReadFmt(GHtml, CLIP_RICH_MAX_BYTES, raw) then
    begin
      {$IFDEF WINDOWS}
      if not CfHtmlUnwrap(raw, S.Html) then
        S.Html := '';
      {$ELSE}
      S.Html := HtmlToUtf8(raw);
      {$ENDIF}
    end;
    if ReadFmt(GRtf, CLIP_RICH_MAX_BYTES, raw) then
      RtfSane(raw, S.Rtf);
    ReadImage(S);
    Result := True;
  except
    S := Default(TClipSnapshot);
    Result := False;
  end;
end;

function AddRaw(AFmt: TClipboardFormat; const AData: RawByteString): Boolean;
var
  ms: TMemoryStream;
begin
  Result := True;
  if (AFmt = 0) or (AData = '') then
    Exit;
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(AData[1], Length(AData));
    ms.Position := 0;
    Result := Clipboard.AddFormat(AFmt, ms);
  finally
    ms.Free;
  end;
end;

function WriteOnce(const S: TClipSnapshot): Boolean;
var
  html, png, dib: RawByteString;
  probe: TClipboardFormat;
  {$IFNDEF WINDOWS}
  img: TClipImage;
  why: string;
  {$ENDIF}
begin
  Result := False;
  if ClipSnapshotEmpty(S) then
    Exit;
  html := S.Html;
  png := S.Png;
  dib := S.Dib;
  {$IFDEF WINDOWS}
  if html <> '' then
    html := CfHtmlWrap(html);
  {$ELSE}
  // hors Windows, seul le PNG est lu par tout le monde
  if (png = '') and (dib <> '') and
     DibDecode(PByte(@dib[1]), Length(dib), img, why) then
    png := PngEncode(img);
  dib := '';
  {$ENDIF}
  try
    NeedFormats;
    Clipboard.Open;
    try
      // AsText vide le cache LCL: le texte d'abord, le reste ensuite
      if S.Text <> '' then
        Clipboard.AsText := UTF8Encode(S.Text)
      else
        Clipboard.Clear;
      Result := AddRaw(GHtml, html) and AddRaw(GRtf, S.Rtf) and
        AddRaw(GDib, dib) and AddRaw(GPng, png);
      if not Result then
        Clipboard.Clear;   // a moitie pose, c'est faux en entier
    finally
      Clipboard.Close;
    end;
    // Close avale l'echec de possession: on relit ce qu'on croit avoir pose
    if S.Text <> '' then probe := CF_TEXT
    else if png <> '' then probe := GPng
    else if dib <> '' then probe := GDib
    else if html <> '' then probe := GHtml
    else probe := GRtf;
    Result := Result and Clipboard.HasFormat(probe);
  except
    Result := False;
  end;
end;

// L'historique du presse-papiers de Windows relit chaque copie dans la foulee
// et tient la serrure pendant ce temps: un refus d'une poignee de ms n'en est
// pas un.
function ClipWriteSnapshot(const S: TClipSnapshot): Boolean;
var
  attempt: Integer;
begin
  Result := False;
  for attempt := 1 to 8 do
  begin
    Result := WriteOnce(S);
    if Result or ClipSnapshotEmpty(S) then
      Exit;
    Sleep(15 * attempt);
  end;
end;

end.
