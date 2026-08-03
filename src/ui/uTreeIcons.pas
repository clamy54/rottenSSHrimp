unit uTreeIcons;

{$mode objfpc}{$H+}

// Catalogue d'icones d'arborescence, PNG embarques en RCDATA
// (TREE_<ID>_<VARIANT>_<TAILLE>). ONDARK/ONLIGHT nomment le FOND, l'inverse des
// repertoires sources "-dark"/"-light": les confondre inverse tout le jeu.
// Les IDs sont stockes dans nodes.icon_id: ne jamais renommer sans alias.

interface

uses
  Classes, SysUtils, Controls, Graphics;

{$I uTreeIconCatalog.inc}

const
  ICON_ROOT_DEFAULT   = 'home';
  ICON_FOLDER_DEFAULT = 'folder';
  ICON_SSH_DEFAULT    = 'device-desktop';
  ICON_RDP_DEFAULT    = 'brand-windows';

// L'index dans cette liste EST l'ImageIndex de la TImageList construite.
function TreeIconCount: Integer;
function TreeIconIdAt(AIndex: Integer): string;
function TreeFolderCount: Integer;

function BuildTreeImageList(AOwner: TComponent;
  APixelsPerInch: Integer): TImageList;

function BuildTreeImageListSized(AOwner: TComponent;
  ASize: Integer): TImageList;

function TreeIconIndex(const AIconId: string): Integer;

function ResolveIconId(const AIconId: string): string;

implementation

uses
  LCLType, uTheme;

type
  TIdAlias = record
    Old, New: string;
  end;

const
  OLD_ID_ALIASES: array[0..8] of TIdAlias = (
    (Old: 'root-rotten';   New: 'home'),
    (Old: 'root-document'; New: 'file'),
    (Old: 'conn-ssh';      New: 'device-desktop'),
    (Old: 'conn-rdp';      New: 'brand-windows'),
    (Old: 'folder-red';    New: 'folder'),
    (Old: 'folder-blue';   New: 'folder'),
    (Old: 'folder-green';  New: 'folder'),
    (Old: 'folder-orange'; New: 'folder'),
    (Old: 'folder-purple'; New: 'folder'));

var
  GIds: array of string;

procedure EnsureCatalog;
var
  i, n: Integer;
begin
  if Length(GIds) > 0 then Exit;
  SetLength(GIds, Length(TREE_FOLDER_IDS) + Length(TREE_HOST_IDS)
    + Length(TREE_EXTENDED_IDS));
  n := 0;
  for i := 0 to High(TREE_FOLDER_IDS) do begin GIds[n] := TREE_FOLDER_IDS[i]; Inc(n); end;
  for i := 0 to High(TREE_HOST_IDS) do begin GIds[n] := TREE_HOST_IDS[i]; Inc(n); end;
  for i := 0 to High(TREE_EXTENDED_IDS) do begin GIds[n] := TREE_EXTENDED_IDS[i]; Inc(n); end;
end;

function TreeIconCount: Integer;
begin
  EnsureCatalog;
  Result := Length(GIds);
end;

function TreeFolderCount: Integer;
begin
  Result := Length(TREE_FOLDER_IDS);
end;

function TreeIconIdAt(AIndex: Integer): string;
begin
  EnsureCatalog;
  if (AIndex >= 0) and (AIndex < Length(GIds)) then
    Result := GIds[AIndex]
  else
    Result := '';
end;

function ResolveIconId(const AIconId: string): string;
var
  i: Integer;
begin
  for i := 0 to High(OLD_ID_ALIASES) do
    if OLD_ID_ALIASES[i].Old = AIconId then
      Exit(OLD_ID_ALIASES[i].New);
  Result := AIconId;
end;

function TreeIconIndex(const AIconId: string): Integer;
var
  id: string;
  i: Integer;
begin
  EnsureCatalog;
  id := ResolveIconId(AIconId);
  for i := 0 to High(GIds) do
    if GIds[i] = id then
      Exit(i);
  Result := 0;
end;

// D'apres la LUMINANCE reelle du fond, pas le nom du theme.
function VariantForSideBg: string;
var
  c: LongInt;
  r, g, b, lum: Integer;
begin
  c := ColorToRGB(clSideBg);
  r := c and $FF;
  g := (c shr 8) and $FF;
  b := (c shr 16) and $FF;
  lum := (r * 299 + g * 587 + b * 114) div 1000;
  if lum < 128 then
    Result := 'ONDARK'
  else
    Result := 'ONLIGHT';
end;

function PickSize(APixelsPerInch: Integer): Integer;
begin
  if APixelsPerInch >= 192 then
    Result := 48
  else if APixelsPerInch >= 144 then
    Result := 32
  else
    Result := 24;
end;

function LoadIconPng(const AIconId, AVariant: string;
  ASize: Integer): TPortableNetworkGraphic;
var
  res: TResourceStream;
  rname: string;
begin
  rname := 'TREE_' + UpperCase(StringReplace(AIconId, '-', '_', [rfReplaceAll]))
    + '_' + AVariant + '_' + IntToStr(ASize);
  res := TResourceStream.Create(HInstance, rname, RT_RCDATA);
  try
    Result := TPortableNetworkGraphic.Create;
    try
      Result.LoadFromStream(res);
    except
      Result.Free;
      raise;
    end;
  finally
    res.Free;
  end;
end;

function BuildTreeImageListSized(AOwner: TComponent;
  ASize: Integer): TImageList;
var
  size, i: Integer;
  variant: string;
  png: TPortableNetworkGraphic;
  bmp: TBitmap;
begin
  EnsureCatalog;
  size := ASize;
  variant := VariantForSideBg;
  Result := TImageList.Create(AOwner);
  Result.Width := size;
  Result.Height := size;
  for i := 0 to High(GIds) do
  begin
    png := LoadIconPng(GIds[i], variant, size);
    try
      bmp := TBitmap.Create;
      try
        bmp.Assign(png);
        Result.Add(bmp, nil);
      finally
        bmp.Free;
      end;
    finally
      png.Free;
    end;
  end;
end;

function BuildTreeImageList(AOwner: TComponent;
  APixelsPerInch: Integer): TImageList;
begin
  Result := BuildTreeImageListSized(AOwner, PickSize(APixelsPerInch));
end;

end.
