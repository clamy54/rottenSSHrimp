unit uFidoPrompt;

{$mode objfpc}{$H+}

// Interface des cles de securite: l'avis « touchez votre cle » pendant une
// session, et l'enrolement d'une nouvelle cle depuis le gestionnaire
// d'identifiants.
//
// L'avis est NON MODAL a dessein: il apparait au milieu d'une connexion, et
// une modale bloquerait la boucle de messages dont les autres onglets ont
// besoin. L'enrolement, lui, est un acte volontaire: la fenetre d'attente y
// est modale, avec un bouton qui annule vraiment (fido_dev_cancel).

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics,
  uSecureBytes, uSshFido, uSshSkKeyGen;

type
  // Petite fenetre sans bouton systeme, posee au-dessus sans voler le focus:
  // l'utilisateur touche sa cle, il ne tape pas dedans.
  TFidoTouchNotice = class
  private
    FForm: TForm;
    FLabel: TLabel;
    FOnCancel: TNotifyEvent;
    procedure CancelClick(Sender: TObject);
  public
    constructor Create(const AText: string; AOnCancel: TNotifyEvent);
    destructor Destroy; override;
    procedure SetText(const AText: string);
    // Retire la fenetre sans la detruire: appelable depuis son propre bouton.
    procedure Hide;
  end;

  // Plomberie commune a TOUS les sites qui lancent un transport (onglet,
  // cluster, rebond, copy-id): l'avis « touchez » et l'invite PIN. Sans elle,
  // une cle a PIN echoue partout ailleurs que dans l'onglet simple, sans un mot.
  // Annuler ferme l'avis et: appelle AOnCancel s'il y en a un, et leve
  // Cancelled pour les boucles d'attente qui n'ont pas d'objet a arreter.
  TFidoSessionPrompts = class
  private
    FNotice: TFidoTouchNotice;
    FOnCancel: TNotifyEvent;
    FCancelled: Boolean;
    procedure NoticeCancel(Sender: TObject);
  public
    constructor Create(AOnCancel: TNotifyEvent);
    destructor Destroy; override;
    procedure SkNotice(AActive: Boolean; const AText: string);
    procedure SkPin(const APrompt: string; out APin: TSecureBytes;
      var ACancelled: Boolean);
    property Cancelled: Boolean read FCancelled;
  end;

// PIN d'une cle de securite. False = l'utilisateur renonce.
function AskFidoPin(const APrompt: string; out APin: TSecureBytes): Boolean;

// Enrole une cle sur le token et rend de quoi creer l'identifiant. False avec
// AErr vide = annulation. Le geste se fait dans un thread: sans cela la fenetre
// d'attente ne se peindrait pas et le bouton Annuler serait inerte.
function EnrollFidoKeyWithDialog(AOwner: TCustomForm;
  const AUserName: string; ARequireUv: Boolean;
  out APrivatePem: TSecureBytes; out APublicLine, AAlgName, AErr: string): Boolean;

implementation

uses
  SyncObjs, uTheme, uAuthPrompt, uSshKeyGen, uSodiumApi, Dialogs;

{ TFidoTouchNotice }

constructor TFidoTouchNotice.Create(const AText: string; AOnCancel: TNotifyEvent);
var
  btn: TButton;
begin
  inherited Create;
  FOnCancel := AOnCancel;
  FForm := TForm.CreateNew(nil);
  FForm.BorderStyle := bsToolWindow;
  FForm.Caption := 'Security key';
  FForm.Position := poScreenCenter;
  FForm.FormStyle := fsStayOnTop;
  FForm.ClientWidth := 380;
  FForm.ClientHeight := 108;

  FLabel := TLabel.Create(FForm);
  FLabel.Parent := FForm;
  FLabel.Left := 16;
  FLabel.Top := 20;
  FLabel.Width := 348;
  FLabel.WordWrap := True;
  FLabel.Caption := AText;

  btn := TButton.Create(FForm);
  btn.Parent := FForm;
  btn.Caption := 'Cancel';
  btn.Left := 276;
  btn.Top := 68;
  btn.Width := 88;
  btn.OnClick := @CancelClick;

  ApplyUiFont(FForm);
  // Show et pas ShowModal: la session continue de vivre derriere, et l'onglet
  // doit rester utilisable. ShowOnTop volerait le focus au terminal.
  FForm.Visible := True;
end;

destructor TFidoTouchNotice.Destroy;
begin
  FForm.Free;
  inherited Destroy;
end;

procedure TFidoTouchNotice.SetText(const AText: string);
begin
  FLabel.Caption := AText;
end;

procedure TFidoTouchNotice.Hide;
begin
  FForm.Visible := False;
end;

procedure TFidoTouchNotice.CancelClick(Sender: TObject);
begin
  if Assigned(FOnCancel) then
    FOnCancel(Sender);
end;

function AskFidoPin(const APrompt: string; out APin: TSecureBytes): Boolean;
begin
  Result := AskSecret(APrompt, APin);
end;

{ TFidoSessionPrompts }

constructor TFidoSessionPrompts.Create(AOnCancel: TNotifyEvent);
begin
  inherited Create;
  FOnCancel := AOnCancel;
end;

destructor TFidoSessionPrompts.Destroy;
begin
  FreeAndNil(FNotice);
  inherited Destroy;
end;

procedure TFidoSessionPrompts.NoticeCancel(Sender: TObject);
begin
  FCancelled := True;
  // On est dans le OnClick du bouton de cette fenetre: la detruire ici, c'est
  // liberer l'objet dont le gestionnaire est encore sur la pile. On la cache;
  // l'avis « inactif » du transport, ou le destructeur, la libere plus tard.
  if FNotice <> nil then
    FNotice.Hide;
  if Assigned(FOnCancel) then
    FOnCancel(Sender);
end;

procedure TFidoSessionPrompts.SkNotice(AActive: Boolean; const AText: string);
begin
  if AActive then
  begin
    if FNotice = nil then
      FNotice := TFidoTouchNotice.Create(AText, @NoticeCancel)
    else
      FNotice.SetText(AText);
  end
  else
    FreeAndNil(FNotice);
end;

procedure TFidoSessionPrompts.SkPin(const APrompt: string;
  out APin: TSecureBytes; var ACancelled: Boolean);
begin
  APin := nil;
  ACancelled := not AskFidoPin(APrompt, APin);
  if ACancelled then
    FCancelled := True;
end;

{ Enrolement }

type
  // L'enrolement bloque jusqu'au geste: il tourne a cote pendant que la
  // fenetre d'attente se repeint et repond au bouton Annuler.
  TEnrollThread = class(TThread)
  private
    FOp: TFidoOperation;
    FApplication, FUserName: string;
    FRequireUv: Boolean;
    FResult: TFidoEnrollment;
    FOk: Boolean;
    FErr: string;
    // Le PIN est demande par le thread UI: la fenetre est a lui. L'echange
    // passe par un evenement (barriere memoire comprise), pas par des champs
    // sondes en boucle: sur ARM64 une publication partielle se verrait.
    FPinWanted: LongInt;      // 0/1, Interlocked
    FPinPrompt: string;
    FPin: TSecureBytes;
    FPinCancelled: Boolean;
    FPinDone: TEvent;
    function PinHook(const AReason: string; out APin: TSecureBytes): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AOp: TFidoOperation; const AApplication, AUserName: string;
      ARequireUv: Boolean);
    destructor Destroy; override;
  end;

constructor TEnrollThread.Create(AOp: TFidoOperation;
  const AApplication, AUserName: string; ARequireUv: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOp := AOp;
  FApplication := AApplication;
  FUserName := AUserName;
  FRequireUv := ARequireUv;
  FPinDone := TEvent.Create(nil, True, False, '');
  FOp.OnPin := @PinHook;
end;

destructor TEnrollThread.Destroy;
begin
  // Le worker peut encore tourner si l'appelant est sorti sur une exception
  // avant son WaitFor: le reveiller s'il attend un PIN, lui retirer le token
  // s'il attend un geste, le rejoindre, et seulement ensuite liberer ce qu'il
  // lit. L'ordre inverse lui faisait attendre un evenement deja detruit.
  Terminate;
  FPinCancelled := True;
  if FPinDone <> nil then
    FPinDone.SetEvent;
  if FOp <> nil then
    FOp.Cancel;
  inherited Destroy;    // rejoint le thread
  if FOp <> nil then
    FOp.OnPin := nil;
  FPinDone.Free;
  FPin.Free;
end;

function TEnrollThread.PinHook(const AReason: string;
  out APin: TSecureBytes): Boolean;
begin
  // On publie la demande et on attend que le thread UI la serve; pas de
  // Synchronize, la boucle d'attente de l'appelant fait deja tourner les
  // messages et un Synchronize s'y emboiterait mal. Les champs sont ecrits
  // AVANT le drapeau Interlocked, et relus APRES l'evenement: les deux posent
  // la barriere qui manquait.
  APin := nil;
  FPinPrompt := AReason;
  FPin := nil;
  FPinCancelled := False;
  FPinDone.ResetEvent;
  InterlockedExchange(FPinWanted, 1);
  while (FPinDone.WaitFor(50) = wrTimeout) and (not Terminated) do ;
  Result := (not FPinCancelled) and (FPin <> nil);
  if Result then
  begin
    APin := FPin;
    FPin := nil;
  end;
end;

procedure TEnrollThread.Execute;
begin
  try
    FOk := FOp.Enroll(FApplication, FUserName, FRequireUv, FResult, FErr);
  except
    on E: Exception do
    begin
      FOk := False;
      FErr := E.Message;
    end;
  end;
end;

type
  TEnrollCancel = class
    Op: TFidoOperation;
    Cancelled: Boolean;
    procedure Click(Sender: TObject);
  end;

procedure TEnrollCancel.Click(Sender: TObject);
begin
  Cancelled := True;
  if Op <> nil then
    Op.Cancel;
end;

function EnrollFidoKeyWithDialog(AOwner: TCustomForm;
  const AUserName: string; ARequireUv: Boolean;
  out APrivatePem: TSecureBytes; out APublicLine, AAlgName, AErr: string): Boolean;
var
  op: TFidoOperation;
  th: TEnrollThread;
  notice: TFidoTouchNotice;
  cancel: TEnrollCancel;
  pin: TSecureBytes;
  check: LongWord;
  comment: string;
begin
  Result := False;
  APrivatePem := nil;
  APublicLine := '';
  AAlgName := '';
  AErr := '';
  if not FidoAvailable then
  begin
    AErr := FidoUnavailableMessage;
    Exit;
  end;

  op := TFidoOperation.Create;
  cancel := TEnrollCancel.Create;
  cancel.Op := op;
  notice := TFidoTouchNotice.Create(
    'Insert your security key and touch it when it blinks.' + LineEnding +
    LineEnding + 'A new SSH key is being created on the key itself.',
    @cancel.Click);
  th := TEnrollThread.Create(op, SK_APPLICATION, AUserName, ARequireUv);
  try
    th.Start;
    while not th.Finished do
    begin
      Application.ProcessMessages;
      if InterlockedExchange(th.FPinWanted, 0) = 1 then
      begin
        notice.SetText('Enter the PIN of your security key.');
        pin := nil;
        if AskFidoPin(th.FPinPrompt, pin) then
        begin
          th.FPin := pin;
          th.FPinCancelled := False;
        end
        else
          th.FPinCancelled := True;
        th.FPinDone.SetEvent;   // apres les ecritures: c'est lui qui les publie
        notice.SetText('Touch your security key.');
      end;
      Sleep(15);
    end;
    th.WaitFor;

    if th.FOk then
    begin
      // Windows laisse choisir entre la cle de securite et Windows Hello. Le
      // second range la cle dans le TPM du poste: elle marche ici, et nulle
      // part ailleurs. Le document, lui, est fait pour voyager.
      if th.FResult.PlatformBound then
        if MessageDlg('Security key',
          'This key was created inside Windows Hello (this computer), not on ' +
          'your removable security key.' + LineEnding + LineEnding +
          'It will work on this machine only: sharing the document with ' +
          'another computer, or another operating system, will not carry it ' +
          'over.' + LineEnding + LineEnding +
          'Keep it anyway?' + LineEnding +
          'Choose No to start over and pick "Security key" in the Windows ' +
          'dialog.', mtWarning, [mbYes, mbNo], 0) <> mrYes then
        begin
          AErr := '';    // l'utilisateur recommence: pas une erreur
          Exit;
        end;
      SodiumEnsureLoaded;
      randombytes_buf(@check, SizeOf(check));
      comment := AUserName;
      if comment = '' then comment := 'rottensshrimp';
      comment := comment + '@rottensshrimp (FIDO2)';
      APublicLine := EncodeSkPublicLine(th.FResult.Alg, th.FResult.PublicKey,
        SK_APPLICATION, comment);
      APrivatePem := EncodeSkPrivatePem(th.FResult.Alg, th.FResult.PublicKey,
        SK_APPLICATION, th.FResult.Flags, th.FResult.KeyHandle, comment, check);
      AAlgName := SkTypeName(th.FResult.Alg);
      Result := True;
    end
    else if cancel.Cancelled or (th.FErr = 'cancelled') then
      AErr := ''    // annulation: pas un echec a signaler
    else
      AErr := th.FErr;
  finally
    // Le key handle a ete recopie dans le PEM (memoire sure); la copie de
    // travail du thread ne doit pas lui survivre dans le tas.
    WipeBytes(th.FResult.KeyHandle);
    th.Free;
    notice.Free;
    op.Free;
    cancel.Free;
  end;
end;

end.
