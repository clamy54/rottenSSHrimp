{ Controles de dialogue aux couleurs du theme: bouton, case a cocher, liste
  deroulante, barre d'onglets. Les versions natives ne se recolorent pas: sous
  Windows avec les styles visuels, un TCheckBox ignore Font.Color (texte noir
  sur fond sombre, illisible), un TButton et un TComboBox en liste restent
  clairs. Ceux-ci se peignent eux-memes, en relisant les couleurs du theme a
  chaque dessin: un changement de theme n'a rien a leur repasser.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uThemedControls;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Controls, StdCtrls, ExtCtrls, Forms, Graphics,
  Menus, LCLType, uTheme;

const
  // Tag d'un TLabel: couleur secondaire (aide) ou d'avertissement.
  THEME_TAG_SECONDARY = 7101;
  THEME_TAG_WARN = 7102;

type
  TThemedButtonGlyph = (tbgNone, tbgEye, tbgEyeCrossed);

  TThemedButton = class(TCustomControl)
  private
    FDefault: Boolean;
    FModalResult: TModalResult;
    FGlyph: TThemedButtonGlyph;
    FHot: Boolean;
    FDown: Boolean;
    procedure SetDefault(AValue: Boolean);
    procedure SetGlyph(AValue: TThemedButtonGlyph);
    procedure DrawEye(ACx, ACy: Integer; AColor: TColor);
  protected
    procedure Paint; override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure TextChanged; override;
    procedure EnabledChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Caption;
    property OnClick;
    // Default: bouton a l'accent. La touche Entree, elle, est routee par la
    // fenetre (voir TNodeDialog.KeyDown): un controle peint ne la recoit
    // que s'il a le focus.
    property Default: Boolean read FDefault write SetDefault;
    property ModalResult: TModalResult read FModalResult write FModalResult;
    property Glyph: TThemedButtonGlyph read FGlyph write SetGlyph;
  end;

  TThemedCheck = class(TCustomControl)
  private
    FChecked: Boolean;
    FHot: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
  protected
    procedure Paint; override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure TextChanged; override;
    procedure EnabledChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Caption;
    property Checked: Boolean read FChecked write SetChecked;
    // Clic ou barre d'espace seulement: poser Checked par code ne notifie pas,
    // comme un TCheckBox dont on ne veut pas les echos.
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // Liste deroulante non editable. Meme surface que le TComboBox qu'elle
  // remplace (Items, ItemIndex, OnChange, Style), pour que le code qui la
  // remplit n'ait pas a changer. La liste s'ouvre en menu aux couleurs du
  // theme (menus de l'appli).
  TThemedCombo = class(TCustomControl)
  private
    FItems: TStringList;
    FItemIndex: Integer;
    FOnChange: TNotifyEvent;
    FStyle: TComboBoxStyle;
    FHot: Boolean;
    FPopup: TPopupMenu;
    procedure SetItemIndex(AValue: Integer);
    function GetItems: TStrings;
    procedure ItemsChanged(Sender: TObject);
    procedure ItemPicked(Sender: TObject);
    procedure PopupClosed(Sender: TObject);
    procedure Pick(AIndex: Integer);
  protected
    procedure Paint; override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure EnabledChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DropDown;
    function Text: string;
    property Items: TStrings read GetItems;
    // Poser ItemIndex par code ne notifie pas: comme un TComboBox.
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    // Garde pour la compatibilite du code d'appel: il n'y a qu'un style.
    property Style: TComboBoxStyle read FStyle write FStyle;
  end;

  TThemedTabs = class(TCustomControl)
  private
    FTabs: TStringList;
    FTabIndex: Integer;
    FHot: Integer;
    // Focus pris a la souris: pas de cadre, il ne sert qu'a qui navigue au
    // clavier et, apres un clic, ressemble a un onglet encadre par erreur.
    FMouseFocus: Boolean;
    FOnChange: TNotifyEvent;
    function TabRect(AIndex: Integer): TRect;
    function TabAt(X, Y: Integer): Integer;
    procedure SetTabIndex(AValue: Integer);
    function GetTabs: TStrings;
  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Tabs: TStrings read GetTabs;
    // Par code: notifie aussi, l'hote affiche la page correspondante.
    property TabIndex: Integer read FTabIndex write SetTabIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

// Fond d'un champ de saisie: a peine detache du fond de la fenetre, dans le
// sens du theme (plus clair en sombre, plus sombre en clair).
function ThemeFieldColor: TColor;
// Texte lisible sur AColor: sombre sur un fond clair, clair sur un fond sombre.
function ContrastTextColor(AColor: TColor): TColor;
// Couleurs d'un TEdit/TMemo.
procedure ThemeField(AEdit: TWinControl);
// Passe AControl et ses enfants aux couleurs du theme: fonds, libelles
// (selon leur Tag), champs. Les controles peints ici se debrouillent seuls.
procedure ThemeControls(AControl: TControl);

{$IFDEF LCLGtk2}
// Les themes GTK2 a moteur (Yaru) ignorent modify_base: d'ou un GtkStyle neuf.
procedure ForceGtk2EntryColors(AEdit: TWinControl; ABase, AText: TColor;
  AZeroPadding: Boolean);
{$ENDIF}

implementation

uses
  uMenuBar
  {$IFDEF LCLGtk2}, gtk2, gdk2, glib2{$ENDIF};

const
  RADIUS = 6;

function ThemeFieldColor: TColor;
begin
  Result := BlendColor(clAppFg, clAppBg, 7);
end;

function ContrastTextColor(AColor: TColor): TColor;
var
  c: LongInt;
  lum: Integer;
begin
  c := ColorToRGB(AColor);
  lum := ((c and $FF) * 299 + ((c shr 8) and $FF) * 587 +
    ((c shr 16) and $FF) * 114) div 1000;
  if lum > 150 then
    Result := RgbHexToColor($1A1A1A)
  else
    Result := RgbHexToColor($FFFFFF);
end;

function BorderColor: TColor;
begin
  Result := BlendColor(clAppFg, clAppBg, 30);
end;

function DisabledText: TColor;
begin
  Result := BlendColor(clAppFg, clAppBg, 45);
end;

{$IFDEF LCLGtk2}
procedure ForceGtk2EntryColors(AEdit: TWinControl; ABase, AText: TColor;
  AZeroPadding: Boolean);
  function GC(c: TColor): TGdkColor;
  var r: LongInt;
  begin
    r := ColorToRGB(c);
    Result.pixel := 0;
    Result.red   := (r and $FF) * 257;         // 0..255 -> 0..65535
    Result.green := ((r shr 8) and $FF) * 257;
    Result.blue  := ((r shr 16) and $FF) * 257;
  end;
var
  w: PGtkWidget;
  cb, ct: TGdkColor;
  st: TGtkStateType;
  style: PGtkStyle;
begin
  AEdit.HandleNeeded;
  if not AEdit.HandleAllocated then Exit;
  w := PGtkWidget(AEdit.Handle);
  cb := GC(ABase);
  ct := GC(AText);
  style := gtk_style_new;
  for st := GTK_STATE_NORMAL to GTK_STATE_INSENSITIVE do
  begin
    style^.base[st] := cb;
    style^.bg[st]   := cb;
    style^.text[st] := ct;
    style^.fg[st]   := ct;
  end;
  if AZeroPadding then
  begin
    // padding a zero: sinon l'entry depasse son cadre et recouvre la bordure
    style^.xthickness := 0;
    style^.ythickness := 0;
  end;
  gtk_widget_set_style(w, style);
  g_object_unref(style);   // le widget en detient desormais une reference
  gtk_widget_queue_resize(w);
end;
{$ENDIF}

procedure ThemeField(AEdit: TWinControl);
begin
  AEdit.Color := ThemeFieldColor;
  AEdit.Font.Color := clAppFg;
  {$IFDEF LCLGtk2}
  if AEdit is TCustomEdit then
    ForceGtk2EntryColors(AEdit, ThemeFieldColor, clAppFg, False);
  {$ENDIF}
end;

type
  // Porte les gestionnaires du cadre des champs: la LCL veut des methodes.
  TFieldFramer = class
    procedure PanelPaint(Sender: TObject);
    procedure FieldFocus(Sender: TObject);
  end;

var
  GFramer: TFieldFramer = nil;

const
  // Tag pose sur un champ dont le cadre est peint par son panneau
  THEME_TAG_FRAMED = 7103;
  FIELD_PAD_X = 7;
  FIELD_PAD_Y = 4;

// Le cadre d'un champ, deduit de ses bornes actuelles (champ deja rentre).
function FieldFrame(AEdit: TControl): TRect;
begin
  if AEdit is TCustomMemo then
    Result := Rect(AEdit.Left - FIELD_PAD_X, AEdit.Top - FIELD_PAD_Y,
      AEdit.Left + AEdit.Width + FIELD_PAD_X,
      AEdit.Top + AEdit.Height + FIELD_PAD_Y)
  else
    Result := Rect(AEdit.Left - FIELD_PAD_X,
      AEdit.Top + AEdit.Height div 2 - 13,
      AEdit.Left + AEdit.Width + FIELD_PAD_X,
      AEdit.Top + AEdit.Height div 2 + 13);
end;

procedure TFieldFramer.PanelPaint(Sender: TObject);
var
  p: TPanel;
  i: Integer;
  c: TControl;
  r: TRect;
begin
  p := TPanel(Sender);
  for i := 0 to p.ControlCount - 1 do
  begin
    c := p.Controls[i];
    if (c.Tag <> THEME_TAG_FRAMED) or (not c.Visible) then Continue;
    r := FieldFrame(c);
    p.Canvas.Brush.Style := bsSolid;
    p.Canvas.Brush.Color := ThemeFieldColor;
    if TWinControl(c).Focused then
    begin
      p.Canvas.Pen.Color := clAccent;
      p.Canvas.Pen.Width := 2;
      p.Canvas.RoundRect(r.Left + 1, r.Top + 1, r.Right, r.Bottom,
        RADIUS, RADIUS);
      p.Canvas.Pen.Width := 1;
    end
    else
    begin
      if c.Enabled then
        p.Canvas.Pen.Color := BorderColor
      else
        p.Canvas.Pen.Color := BlendColor(clAppFg, clAppBg, 16);
      p.Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, RADIUS, RADIUS);
    end;
  end;
end;

procedure TFieldFramer.FieldFocus(Sender: TObject);
begin
  if (Sender is TControl) and (TControl(Sender).Parent <> nil) then
    TControl(Sender).Parent.Invalidate;
end;

// Le cadre natif d'un champ (blanc et epais sous Windows en theme sombre)
// jure avec les listes deroulantes peintes. On l'enleve, on rentre le champ
// dans ses anciennes bornes, et son panneau peint un cadre arrondi a la
// place, a l'accent quand le champ a le focus.
procedure FrameField(AEdit: TCustomEdit);
var
  l, t, w, h, eh: Integer;
  p: TPanel;
begin
  if not (AEdit.Parent is TPanel) then Exit;
  if AEdit.Tag = THEME_TAG_FRAMED then Exit;
  p := TPanel(AEdit.Parent);
  l := AEdit.Left;
  t := AEdit.Top;
  w := AEdit.Width;
  h := AEdit.Height;
  AEdit.BorderStyle := bsNone;
  if AEdit is TCustomMemo then
    AEdit.SetBounds(l + FIELD_PAD_X, t + FIELD_PAD_Y, w - 2 * FIELD_PAD_X,
      h - 2 * FIELD_PAD_Y)
  else
  begin
    // hauteur posee, pas calculee: sans handle, AutoSize ne sait pas encore
    AEdit.AutoSize := False;
    eh := UiTextHeight('Ag') + 2;
    AEdit.SetBounds(l + FIELD_PAD_X, t + (h - eh) div 2, w - 2 * FIELD_PAD_X,
      eh);
  end;
  AEdit.Tag := THEME_TAG_FRAMED;
  if GFramer = nil then
    GFramer := TFieldFramer.Create;
  p.OnPaint := @GFramer.PanelPaint;
  if not Assigned(AEdit.OnEnter) then
    AEdit.OnEnter := @GFramer.FieldFocus;
  if not Assigned(AEdit.OnExit) then
    AEdit.OnExit := @GFramer.FieldFocus;
end;

procedure ThemeControls(AControl: TControl);
var
  i: Integer;
begin
  if AControl = nil then Exit;
  if AControl is TCustomForm then
  begin
    TCustomForm(AControl).Color := clAppBg;
    TCustomForm(AControl).Font.Color := clAppFg;
  end
  else if AControl is TPanel then
  begin
    TPanel(AControl).BevelOuter := bvNone;
    TPanel(AControl).ParentColor := False;
    TPanel(AControl).Color := clAppBg;
    TPanel(AControl).Font.Color := clAppFg;
  end
  else if AControl is TLabel then
  begin
    // Pas de ParentFont: ApplyUiFont a pose nom et taille un par un, la
    // couleur doit l'etre aussi, sinon elle reste au noir du systeme.
    case AControl.Tag of
      THEME_TAG_SECONDARY: AControl.Font.Color := clTextSecondary;
      THEME_TAG_WARN: AControl.Font.Color := clScpWarn;
    else
      AControl.Font.Color := clAppFg;
    end;
    TLabel(AControl).Transparent := True;
  end
  else if (AControl is TCustomEdit) then
  begin
    ThemeField(TWinControl(AControl));
    FrameField(TCustomEdit(AControl));
  end;
  if AControl is TWinControl then
    for i := 0 to TWinControl(AControl).ControlCount - 1 do
      ThemeControls(TWinControl(AControl).Controls[i]);
end;

procedure FocusRing(ACanvas: TCanvas; const R: TRect);
begin
  ACanvas.Brush.Style := bsClear;
  ACanvas.Pen.Style := psSolid;
  ACanvas.Pen.Width := 2;
  ACanvas.Pen.Color := clAccent;
  ACanvas.RoundRect(R.Left + 1, R.Top + 1, R.Right, R.Bottom,
    RADIUS, RADIUS);
  ACanvas.Pen.Width := 1;
end;

{ TThemedButton }

constructor TThemedButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  Width := 110;
  Height := 30;
end;

procedure TThemedButton.SetDefault(AValue: Boolean);
begin
  if FDefault = AValue then Exit;
  FDefault := AValue;
  Invalidate;
end;

procedure TThemedButton.SetGlyph(AValue: TThemedButtonGlyph);
begin
  if FGlyph = AValue then Exit;
  FGlyph := AValue;
  Invalidate;
end;

procedure TThemedButton.Click;
var
  f: TCustomForm;
begin
  if not Enabled then Exit;
  // comme TButton: le resultat d'abord, puis le OnClick qui peut l'annuler
  if FModalResult <> mrNone then
  begin
    f := GetParentForm(Self);
    if f <> nil then
      f.ModalResult := FModalResult;
  end;
  inherited Click;
end;

procedure TThemedButton.DrawEye(ACx, ACy: Integer; AColor: TColor);
begin
  Canvas.Pen.Color := AColor;
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsClear;
  Canvas.Ellipse(ACx - 7, ACy - 4, ACx + 8, ACy + 5);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := AColor;
  Canvas.Ellipse(ACx - 2, ACy - 2, ACx + 3, ACy + 3);
  if FGlyph = tbgEyeCrossed then
  begin
    Canvas.Pen.Width := 2;
    Canvas.Line(ACx - 6, ACy + 6, ACx + 7, ACy - 6);
    Canvas.Pen.Width := 1;
  end;
end;

procedure TThemedButton.Paint;
var
  r: TRect;
  bg, border, fg: TColor;
  tw, th: Integer;
begin
  r := ClientRect;
  // fond du parent sous les coins arrondis
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(r);

  if not Enabled then
  begin
    bg := BlendColor(clAppFg, clAppBg, 6);
    border := BlendColor(clAppFg, clAppBg, 16);
    fg := DisabledText;
  end
  else if FDefault then
  begin
    bg := clAccent;
    if FDown then
      bg := BlendColor(clAppBg, clAccent, 22)
    else if FHot then
      bg := BlendColor(clAppFg, clAccent, 14);
    border := bg;
    fg := ContrastTextColor(bg);
  end
  else
  begin
    if FDown then
      bg := BlendColor(clAppFg, clAppBg, 24)
    else if FHot then
      bg := BlendColor(clAppFg, clAppBg, 17)
    else
      bg := BlendColor(clAppFg, clAppBg, 11);
    border := BorderColor;
    fg := clAppFg;
  end;
  if FGlyph <> tbgNone then
  begin
    // bouton-icone (l'oeil du mot de passe): discret tant qu'on ne le survole pas
    if not (FHot or FDown) then
    begin
      bg := clAppBg;
      border := clAppBg;
    end;
  end;

  Canvas.Brush.Color := bg;
  Canvas.Pen.Color := border;
  Canvas.Pen.Width := 1;
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, RADIUS, RADIUS);

  if FGlyph <> tbgNone then
    DrawEye(r.Width div 2, r.Height div 2, fg)
  else
  begin
    Canvas.Font := Font;
    Canvas.Font.Color := fg;
    Canvas.Brush.Style := bsClear;
    tw := Canvas.TextWidth(Caption);
    th := Canvas.TextHeight('Ag');
    Canvas.TextOut((r.Width - tw) div 2, (r.Height - th) div 2, Caption);
  end;
  if Focused then
    FocusRing(Canvas, r);
  Canvas.Brush.Style := bsSolid;
end;

procedure TThemedButton.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TThemedButton.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  FDown := False;
  Invalidate;
end;

procedure TThemedButton.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FDown := True;
    if CanFocus then SetFocus;
    Invalidate;
  end;
end;

procedure TThemedButton.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  // le clic lui-meme vient de la LCL (csClickEvents), si on relache DEDANS
  FDown := False;
  Invalidate;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TThemedButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key in [VK_SPACE, VK_RETURN]) and (Shift = []) then
  begin
    Key := 0;
    Click;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TThemedButton.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TThemedButton.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TThemedButton.TextChanged;
begin
  inherited TextChanged;
  Invalidate;
end;

procedure TThemedButton.EnabledChanged;
begin
  inherited EnabledChanged;
  Invalidate;
end;

{ TThemedCheck }

constructor TThemedCheck.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  Height := 22;
  Width := 200;
end;

procedure TThemedCheck.SetChecked(AValue: Boolean);
begin
  if FChecked = AValue then Exit;
  FChecked := AValue;
  Invalidate;
end;

procedure TThemedCheck.Click;
begin
  if not Enabled then Exit;
  FChecked := not FChecked;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
  inherited Click;
end;

procedure TThemedCheck.Paint;
const
  BOX = 16;
var
  r, b: TRect;
  boxY, th: Integer;
  fg: TColor;
begin
  r := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(r);

  boxY := (r.Height - BOX) div 2;
  b := Rect(1, boxY, 1 + BOX, boxY + BOX);
  if FChecked and Enabled then
  begin
    Canvas.Brush.Color := clAccent;
    Canvas.Pen.Color := clAccent;
  end
  else
  begin
    Canvas.Brush.Color := ThemeFieldColor;
    if FHot and Enabled then
      Canvas.Pen.Color := BlendColor(clAppFg, clAppBg, 55)
    else
      Canvas.Pen.Color := BorderColor;
  end;
  if FChecked and (not Enabled) then
    Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 25);
  Canvas.RoundRect(b.Left, b.Top, b.Right, b.Bottom, 4, 4);
  if FChecked then
  begin
    Canvas.Pen.Color := ContrastTextColor(Canvas.Brush.Color);
    Canvas.Pen.Width := 2;
    Canvas.Line(b.Left + 4, b.Top + 8, b.Left + 7, b.Top + 11);
    Canvas.Line(b.Left + 7, b.Top + 11, b.Left + 12, b.Top + 4);
    Canvas.Pen.Width := 1;
  end;
  if Focused then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := clAccent;
    Canvas.Pen.Width := 2;
    Canvas.RoundRect(b.Left - 1, b.Top - 1, b.Right + 1, b.Bottom + 1, 5, 5);
    Canvas.Pen.Width := 1;
  end;

  if Enabled then fg := clAppFg else fg := DisabledText;
  Canvas.Font := Font;
  Canvas.Font.Color := fg;
  Canvas.Brush.Style := bsClear;
  th := Canvas.TextHeight('Ag');
  Canvas.TextOut(BOX + 10, (r.Height - th) div 2, Caption);
  Canvas.Brush.Style := bsSolid;
end;

procedure TThemedCheck.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TThemedCheck.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  Invalidate;
end;

procedure TThemedCheck.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_SPACE) and (Shift = []) then
  begin
    Key := 0;
    Click;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TThemedCheck.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TThemedCheck.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TThemedCheck.TextChanged;
begin
  inherited TextChanged;
  Invalidate;
end;

procedure TThemedCheck.EnabledChanged;
begin
  inherited EnabledChanged;
  Invalidate;
end;

{ TThemedCombo }

constructor TThemedCombo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  FItems := TStringList.Create;
  FItems.OnChange := @ItemsChanged;
  FItemIndex := -1;
  FStyle := csDropDownList;
  Height := 26;
  Width := 200;
end;

destructor TThemedCombo.Destroy;
begin
  FItems.OnChange := nil;
  FItems.Free;
  inherited Destroy;
end;

function TThemedCombo.GetItems: TStrings;
begin
  Result := FItems;
end;

procedure TThemedCombo.ItemsChanged(Sender: TObject);
begin
  if FItemIndex >= FItems.Count then
    FItemIndex := -1;
  Invalidate;
end;

procedure TThemedCombo.SetItemIndex(AValue: Integer);
begin
  if (AValue < -1) or (AValue >= FItems.Count) then
    AValue := -1;
  if FItemIndex = AValue then Exit;
  FItemIndex := AValue;
  Invalidate;
end;

function TThemedCombo.Text: string;
begin
  if (FItemIndex >= 0) and (FItemIndex < FItems.Count) then
    Result := FItems[FItemIndex]
  else
    Result := '';
end;

procedure TThemedCombo.Pick(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) or (AIndex = FItemIndex) then
    Exit;
  FItemIndex := AIndex;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TThemedCombo.ItemPicked(Sender: TObject);
begin
  Pick(TMenuItem(Sender).Tag);
end;

procedure TThemedCombo.PopupClosed(Sender: TObject);
begin
  Invalidate;
end;

procedure TThemedCombo.DropDown;
var
  i: Integer;
  mi: TMenuItem;
  p: TPoint;
begin
  if (not Enabled) or (FItems.Count = 0) then Exit;
  // reconstruit a chaque ouverture: Items a pu changer entre-temps
  FreeAndNil(FPopup);
  FPopup := TPopupMenu.Create(Self);
  FPopup.OnClose := @PopupClosed;
  for i := 0 to FItems.Count - 1 do
  begin
    mi := TMenuItem.Create(FPopup);
    mi.Caption := StringReplace(FItems[i], '&', '&&', [rfReplaceAll]);
    mi.Tag := i;
    mi.RadioItem := True;
    mi.Checked := i = FItemIndex;
    mi.OnClick := @ItemPicked;
    FPopup.Items.Add(mi);
  end;
  ThemePopupMenu(FPopup);
  p := ClientToScreen(Point(0, Height));
  FPopup.PopUp(p.X, p.Y);
end;

procedure TThemedCombo.Paint;
var
  r: TRect;
  th, cx, cy: Integer;
  fg: TColor;
begin
  r := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(r);
  if Enabled and FHot then
    Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 11)
  else
    Canvas.Brush.Color := ThemeFieldColor;
  Canvas.Pen.Color := BorderColor;
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, RADIUS, RADIUS);

  if Enabled then fg := clAppFg else fg := DisabledText;
  Canvas.Font := Font;
  Canvas.Font.Color := fg;
  Canvas.Brush.Style := bsClear;
  th := Canvas.TextHeight('Ag');
  Canvas.TextRect(Rect(8, 0, r.Right - 26, r.Bottom), 8,
    (r.Height - th) div 2, Text);

  // chevron
  cx := r.Right - 14;
  cy := r.Height div 2;
  Canvas.Pen.Color := fg;
  Canvas.Pen.Width := 2;
  Canvas.Line(cx - 4, cy - 2, cx, cy + 2);
  Canvas.Line(cx, cy + 2, cx + 4, cy - 2);
  Canvas.Pen.Width := 1;
  if Focused then
    FocusRing(Canvas, r);
  Canvas.Brush.Style := bsSolid;
end;

procedure TThemedCombo.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TThemedCombo.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  Invalidate;
end;

procedure TThemedCombo.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if CanFocus then SetFocus;
  DropDown;
end;

procedure TThemedCombo.KeyDown(var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_UP:
      begin
        Pick(FItemIndex - 1);
        Key := 0;
      end;
    VK_DOWN:
      begin
        if ssAlt in Shift then
          DropDown
        else
          Pick(FItemIndex + 1);
        Key := 0;
      end;
    VK_SPACE, VK_F4:
      begin
        DropDown;
        Key := 0;
      end;
  end;
  if Key <> 0 then
    inherited KeyDown(Key, Shift);
end;

procedure TThemedCombo.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TThemedCombo.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TThemedCombo.EnabledChanged;
begin
  inherited EnabledChanged;
  Invalidate;
end;

{ TThemedTabs }

constructor TThemedTabs.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  FTabs := TStringList.Create;
  FTabIndex := 0;
  FHot := -1;
  Height := 32;
end;

destructor TThemedTabs.Destroy;
begin
  FTabs.Free;
  inherited Destroy;
end;

function TThemedTabs.GetTabs: TStrings;
begin
  Result := FTabs;
end;

function TThemedTabs.TabRect(AIndex: Integer): TRect;
var
  i, x, w: Integer;
begin
  x := 0;
  Result := Rect(0, 0, 0, 0);
  for i := 0 to FTabs.Count - 1 do
  begin
    w := UiTextWidth(FTabs[i]) + 32;
    if i = AIndex then
      Exit(Rect(x, 0, x + w, ClientHeight));
    Inc(x, w + 2);
  end;
end;

function TThemedTabs.TabAt(X, Y: Integer): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to FTabs.Count - 1 do
    if PtInRect(TabRect(i), Point(X, Y)) then
      Exit(i);
end;

procedure TThemedTabs.SetTabIndex(AValue: Integer);
begin
  if (AValue < 0) or (AValue >= FTabs.Count) or (AValue = FTabIndex) then
    Exit;
  FTabIndex := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TThemedTabs.Paint;
var
  i, th: Integer;
  r: TRect;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(ClientRect);
  // filet de base: les onglets reposent dessus
  Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 18);
  Canvas.FillRect(Rect(0, ClientHeight - 1, ClientWidth, ClientHeight));

  Canvas.Font := Font;
  th := Canvas.TextHeight('Ag');
  for i := 0 to FTabs.Count - 1 do
  begin
    r := TabRect(i);
    if (i = FHot) and (i <> FTabIndex) then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 7);
      Canvas.FillRect(Rect(r.Left, r.Top, r.Right, r.Bottom - 1));
    end;
    Canvas.Brush.Style := bsClear;
    if i = FTabIndex then
    begin
      Canvas.Font.Color := clAppFg;
      Canvas.Font.Style := [fsBold];
    end
    else
    begin
      Canvas.Font.Color := clTextSecondary;
      Canvas.Font.Style := [];
    end;
    Canvas.TextOut(r.Left + (r.Width - Canvas.TextWidth(FTabs[i])) div 2,
      (r.Height - th) div 2 - 1, FTabs[i]);
    if i = FTabIndex then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := clAccent;
      Canvas.FillRect(Rect(r.Left + 4, r.Bottom - 3, r.Right - 4, r.Bottom));
      if Focused and (not FMouseFocus) then
      begin
        Canvas.Brush.Style := bsClear;
        Canvas.Pen.Color := clAccent;
        Canvas.RoundRect(r.Left + 2, r.Top + 2, r.Right - 2, r.Bottom - 5,
          RADIUS, RADIUS);
      end;
    end;
  end;
  Canvas.Font.Style := [];
  Canvas.Brush.Style := bsSolid;
end;

procedure TThemedTabs.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  h: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  h := TabAt(X, Y);
  if h <> FHot then
  begin
    FHot := h;
    Invalidate;
  end;
end;

procedure TThemedTabs.MouseLeave;
begin
  inherited MouseLeave;
  if FHot <> -1 then
  begin
    FHot := -1;
    Invalidate;
  end;
end;

procedure TThemedTabs.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  i: Integer;
begin
  FMouseFocus := True;
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  i := TabAt(X, Y);
  if i >= 0 then
    SetTabIndex(i);
  Invalidate;
end;

procedure TThemedTabs.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if FMouseFocus then
  begin
    FMouseFocus := False;
    Invalidate;
  end;
  case Key of
    VK_LEFT:
      begin
        SetTabIndex(FTabIndex - 1);
        Key := 0;
      end;
    VK_RIGHT:
      begin
        SetTabIndex(FTabIndex + 1);
        Key := 0;
      end;
  end;
  if Key <> 0 then
    inherited KeyDown(Key, Shift);
end;

procedure TThemedTabs.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TThemedTabs.DoExit;
begin
  inherited DoExit;
  FMouseFocus := False;
  Invalidate;
end;

end.
