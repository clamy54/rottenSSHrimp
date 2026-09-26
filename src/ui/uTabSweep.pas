{ Balayage sur instantane des onglets de session.

  Visiter un onglet rend la main a la boucle LCL (modale, join du worker,
  AskHostKey): un DeferredClose en attente y libere un onglet en plein for.
  Donc liste figee, et chaque POINTEUR revalide contre la collection vivante
  avant usage, sans jamais dereferencer un mort. Un TTabSheet detruit quitte
  seul le PageControl: absent = libere.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uTabSweep;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  // Le filtre vit ici: instantane et revalidation, MEME critere.
  ITabList = interface
    ['{4E5A2C10-9B3D-4F71-A6C2-1D7E8F0A2B34}']
    function RawCount: Integer;
    // pointeur opaque, jamais dereference
    function RawItem(AIndex: Integer): Pointer;
    function IsSessionTab(APtr: Pointer): Boolean;
  end;

  // False interrompt. Le visiteur PEUT liberer l'onglet.
  TTabVisitor = function(APtr: Pointer): Boolean of object;

procedure SnapshotSessionTabs(const AList: ITabList; ASnap: TFPList);

function TabIsLive(const AList: ITabList; APtr: Pointer): Boolean;

// AReverse: de la fin vers le debut, pour les passes qui liberent
function SweepSnapshot(const AList: ITabList; ASnap: TFPList;
  AReverse: Boolean; AVisit: TTabVisitor): Boolean;

implementation

procedure SnapshotSessionTabs(const AList: ITabList; ASnap: TFPList);
var
  i: Integer;
begin
  ASnap.Clear;
  if AList = nil then Exit;
  for i := 0 to AList.RawCount - 1 do
    if AList.IsSessionTab(AList.RawItem(i)) then
      ASnap.Add(AList.RawItem(i));
end;

function TabIsLive(const AList: ITabList; APtr: Pointer): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (AList = nil) or (APtr = nil) then Exit;
  for i := 0 to AList.RawCount - 1 do
    if AList.RawItem(i) = APtr then Exit(True);
end;

function SweepSnapshot(const AList: ITabList; ASnap: TFPList;
  AReverse: Boolean; AVisit: TTabVisitor): Boolean;
var
  i: Integer;
begin
  Result := True;
  if (ASnap = nil) or (AVisit = nil) then Exit;
  if AReverse then
  begin
    for i := ASnap.Count - 1 downto 0 do
      // a CHAQUE tour: le visiteur precedent a pu en liberer d'autres
      if TabIsLive(AList, ASnap[i]) then
        if not AVisit(ASnap[i]) then Exit(False);
  end
  else
  begin
    for i := 0 to ASnap.Count - 1 do
      if TabIsLive(AList, ASnap[i]) then
        if not AVisit(ASnap[i]) then Exit(False);
  end;
end;

end.
