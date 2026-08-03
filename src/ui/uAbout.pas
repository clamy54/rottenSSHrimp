unit uAbout;

{$mode objfpc}{$H+}

// Logo pris dans la ressource PNG APPICON_PNG, pas dans MAINICON: sous gtk2 la
// conversion TIcon->bitmap sort des pixels stries au-dela de la 16x16.

interface

procedure ShowAbout;

implementation

uses
  Classes, SysUtils, Types, Forms, Controls, StdCtrls, ExtCtrls, Graphics,
  LCLIntf, uTheme, uVersion;

type
  TAboutForm = class(TForm)
  public
    procedure LinkClick(Sender: TObject);
  end;

procedure TAboutForm.LinkClick(Sender: TObject);
begin
  OpenURL(TLabel(Sender).Caption);
end;

// annee lue A L'EXECUTION: pas de date figee a recompiler chaque 1er janvier
function CopyrightLine: string;
const
  FIRST_YEAR = 2024;
var
  y, m, d: Word;
begin
  DecodeDate(Now, y, m, d);
  if y > FIRST_YEAR then
    Result := Format('(c) %d - %d Cyril LAMY', [FIRST_YEAR, y])
  else
    Result := Format('(c) %d Cyril LAMY', [FIRST_YEAR]);
end;

function AddLabel(AForm: TAboutForm; ATop: Integer; const AText: string;
  ALink: Boolean; ASize: Integer = 0; ABold: Boolean = False): TLabel;
begin
  Result := TLabel.Create(AForm);
  Result.Parent := AForm;
  Result.Caption := AText;
  Result.AutoSize := True;
  Result.Font.Color := clAppFg;
  if ASize > 0 then Result.Font.Size := ASize;
  if ABold then Result.Font.Style := Result.Font.Style + [fsBold];
  if ALink then
  begin
    Result.Font.Color := clAccent;
    Result.Font.Style := Result.Font.Style + [fsUnderline];
    Result.Cursor := crHandPoint;
    Result.OnClick := @AForm.LinkClick;
  end;
  Result.Anchors := [akTop];
  Result.AnchorHorizontalCenterTo(AForm);
  Result.Top := ATop;
end;

// avance AY: la liste des composants tiers s'allonge, on ne recalcule pas
// l'arithmetique verticale a la main a chaque ajout
procedure AddCredit(AForm: TAboutForm; var AY: Integer;
  const AText, AUrl: string);
begin
  AddLabel(AForm, AY, AText, False);
  Inc(AY, 22);
  AddLabel(AForm, AY, AUrl, True);
  Inc(AY, 28);
end;

function LoadLogo(AImg: TImage): Boolean;
var
  rs: TResourceStream;
  png: TPortableNetworkGraphic;
begin
  Result := False;
  try
    rs := TResourceStream.Create(HInstance, 'APPICON_PNG', RT_RCDATA);
    try
      png := TPortableNetworkGraphic.Create;
      try
        png.LoadFromStream(rs);
        AImg.Picture.Assign(png);
        Result := True;
      finally
        png.Free;
      end;
    finally
      rs.Free;
    end;
  except
    // ressource absente: repli sur MAINICON
  end;
end;

procedure ShowAbout;
var
  f: TAboutForm;
  img: TImage;
  ico: TIcon;
  b: TButton;
  y: Integer;
begin
  f := TAboutForm.CreateNew(nil);
  try
    f.Caption := 'About ' + RSSH_APP_NAME;
    f.BorderStyle := bsDialog;
    f.Position := poMainFormCenter;
    f.Color := clAppBg;
    f.Width := 560;

    img := TImage.Create(f);
    img.Parent := f;
    img.SetBounds((f.ClientWidth - 96) div 2, 16, 96, 96);
    img.Stretch := True;
    img.Proportional := True;
    img.Center := True;
    if not LoadLogo(img) then
      try
        ico := TIcon.Create;
        try
          ico.LoadFromResourceName(HInstance, 'MAINICON');
          ico.Current := ico.GetBestIndexForSize(Size(128, 128));
          img.Picture.Assign(ico);
        finally
          ico.Free;
        end;
      except
        // pas d'icone liee: boite sans logo
      end;

    y := 124;
    AddLabel(f, y, RSSH_APP_NAME + ' ' + RSSH_VERSION, False, 15, True);
    Inc(y, 38);
    AddLabel(f, y, RSSH_SLOGAN, False);
    Inc(y, 30);
    AddLabel(f, y, CopyrightLine, False);
    Inc(y, 24);
    AddLabel(f, y, 'Released under the ' + RSSH_LICENSE + ' license', False);
    Inc(y, 30);
    AddLabel(f, y, RSSH_URL, True);
    Inc(y, 34);
    AddCredit(f, y, RSSH_APP_NAME + ' uses the Monaspace font family:',
      'https://monaspace.githubnext.com/');
    AddCredit(f, y, 'Tree icons from the Tabler icon set (MIT):',
      'https://tabler.io/icons');
    AddCredit(f, y, 'and from the Papirus icon theme (GPL-3.0):',
      'https://github.com/PapirusDevelopmentTeam/papirus-icon-theme');
    // licences relevees dans LICENSES/THIRD-PARTY-NOTICES.md, pas de memoire
    AddCredit(f, y, 'SSH sessions use libssh2 (BSD-3-Clause):',
      'https://libssh2.org/');
    AddCredit(f, y, 'RDP sessions use FreeRDP (Apache-2.0):',
      'https://www.freerdp.com/');
    AddCredit(f, y, 'VNC sessions use libvncclient (GPL-2.0-or-later):',
      'https://libvnc.github.io/');
    AddCredit(f, y, 'Encryption uses libsodium (ISC):',
      'https://libsodium.org/');
    AddCredit(f, y, RSSH_APP_NAME + ' also uses SQLite (public domain):',
      'https://sqlite.org/');

    b := TButton.Create(f);
    b.Parent := f;
    b.Caption := 'Close';
    b.ModalResult := mrOk;
    b.Default := True;
    b.Cancel := True;
    // ClientHeight pose EN DERNIER: peu fiable a la creation sous Cocoa
    b.SetBounds((f.ClientWidth - 90) div 2, y + 6, 90, 30);
    f.ClientHeight := y + 6 + 30 + 16;

    ApplyUiFont(f);
    f.ShowModal;
  finally
    f.Free;
  end;
end;

end.
