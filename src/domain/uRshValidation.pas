unit uRshValidation;

{$mode objfpc}{$H+}

// Validation des entrees utilisateur. Message d'erreur vide = valeur
// acceptable; la valeur normalisee (trim) ressort par le parametre var.

interface

const
  SSH_DEFAULT_PORT = 22;
  RDP_DEFAULT_PORT = 3389;
  VNC_DEFAULT_PORT = 5900;
  RDP_GATEWAY_DEFAULT_PORT = 443;

function ValidateName(var AValue: string; out AErr: string): Boolean;

function ValidateHostname(var AValue: string; out AErr: string): Boolean;

function ValidatePort(AValue: Int64; out AErr: string): Boolean;

function ValidateDescription(const AValue: string; out AErr: string): Boolean;

// DEFENSE contre l'injection: le nom finit dans une ligne de
// commande shell distante, et le jeu Docker/Podman n'a aucun metacaractere.
function ValidateContainerName(var AValue: string; out AErr: string): Boolean;

// Meme defense pour kubectl, jeu RFC 1123 minuscule. Name =
// sous-domaine du pod (253, points admis), Label = un seul label (63, sans).
function ValidateK8sName(var AValue: string; out AErr: string): Boolean;
function ValidateK8sLabel(var AValue: string; out AErr: string): Boolean;

implementation

uses
  SysUtils, uCryptoPolicy;

function HasControlChars(const S: string): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 1 to Length(S) do
    if S[i] < #32 then Exit;
  Result := False;
end;

function Utf8Chars(const S: string): Integer;
begin
  Result := Length(UTF8Decode(S));
end;

function ValidateName(var AValue: string; out AErr: string): Boolean;
begin
  Result := False;
  AErr := '';
  AValue := Trim(AValue);
  if AValue = '' then
  begin
    AErr := 'The name cannot be empty.';
    Exit;
  end;
  if HasControlChars(AValue) then
  begin
    AErr := 'The name contains control characters.';
    Exit;
  end;
  if Utf8Chars(AValue) > MAX_NAME_CHARS then
  begin
    AErr := Format('The name exceeds %d characters.', [MAX_NAME_CHARS]);
    Exit;
  end;
  Result := True;
end;

function ValidateHostname(var AValue: string; out AErr: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  AErr := '';
  AValue := Trim(AValue);
  if AValue = '' then
  begin
    AErr := 'The hostname cannot be empty.';
    Exit;
  end;
  if HasControlChars(AValue) then
  begin
    AErr := 'The hostname contains control characters.';
    Exit;
  end;
  if Length(AValue) > MAX_HOSTNAME_CHARS then
  begin
    AErr := Format('The hostname exceeds %d characters.',
      [MAX_HOSTNAME_CHARS]);
    Exit;
  end;
  if Pos('://', AValue) > 0 then
  begin
    AErr := 'Enter a hostname, not a URI.';
    Exit;
  end;
  for i := 1 to Length(AValue) do
    if AValue[i] in [' ', '/', '\', '@', '?', '#'] then
    begin
      AErr := 'Invalid character in the hostname.';
      Exit;
    end;
  Result := True;
end;

function ValidatePort(AValue: Int64; out AErr: string): Boolean;
begin
  Result := (AValue >= 1) and (AValue <= 65535);
  if Result then
    AErr := ''
  else
    AErr := 'The port must be between 1 and 65535.';
end;

function ValidateDescription(const AValue: string; out AErr: string): Boolean;
begin
  Result := Length(AValue) <= MAX_DESCRIPTION_BYTES;
  if Result then
    AErr := ''
  else
    AErr := 'The description is too long.';
end;

function ValidateContainerName(var AValue: string; out AErr: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  AErr := '';
  AValue := Trim(AValue);
  if AValue = '' then
  begin
    AErr := 'The container name cannot be empty.';
    Exit;
  end;
  if Length(AValue) > 255 then
  begin
    AErr := 'The container name is too long.';
    Exit;
  end;
  c := AValue[1];
  if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
          ((c >= '0') and (c <= '9'))) then
  begin
    AErr := 'The container name must start with a letter or digit.';
    Exit;
  end;
  for i := 2 to Length(AValue) do
  begin
    c := AValue[i];
    if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
            ((c >= '0') and (c <= '9')) or (c = '_') or (c = '.') or
            (c = '-')) then
    begin
      AErr := 'The container name may contain only letters, digits, ' +
        '''_'', ''.'' and ''-''.';
      Exit;
    end;
  end;
  Result := True;
end;

function IsLowerAlnum(C: Char): Boolean; inline;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'));
end;

function ValidateK8sCore(var AValue: string; AAllowDot: Boolean;
  AMaxLen: Integer; const AKind: string; out AErr: string): Boolean;
var
  i, labLen: Integer;
  c: Char;
begin
  Result := False;
  AErr := '';
  AValue := Trim(AValue);
  if AValue = '' then
  begin
    AErr := 'The ' + AKind + ' cannot be empty.';
    Exit;
  end;
  if Length(AValue) > AMaxLen then
  begin
    AErr := 'The ' + AKind + ' is too long.';
    Exit;
  end;
  // RFC 1123 vaut pour CHAQUE label entre points, pas seulement pour le nom
  // entier: 64 x 'a' + '.b', 'a..b' et 'a-.b' passaient, refuses cote cluster.
  if AAllowDot then
  begin
    labLen := 0;
    for i := 1 to Length(AValue) do
      if AValue[i] = '.' then
        labLen := 0
      else
      begin
        Inc(labLen);
        if labLen > 63 then
        begin
          AErr := 'Each part of the ' + AKind + ' must be at most ' +
            '63 characters long.';
          Exit;
        end;
      end;
  end;
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    if ((c >= 'a') and (c <= 'z')) or ((c >= '0') and (c <= '9')) then
      Continue;
    if (c = '-') or (AAllowDot and (c = '.')) then
    begin
      if (i = 1) or (i = Length(AValue)) then
      begin
        AErr := 'The ' + AKind + ' must start and end with a ' +
          'lowercase letter or digit.';
        Exit;
      end;
      if AAllowDot then
      begin
        if (c = '.') and (not IsLowerAlnum(AValue[i - 1])) then
        begin
          AErr := 'Each part of the ' + AKind + ' must start and end with ' +
            'a lowercase letter or digit.';
          Exit;
        end;
        if (c = '.') and (not IsLowerAlnum(AValue[i + 1])) then
        begin
          AErr := 'Each part of the ' + AKind + ' must start and end with ' +
            'a lowercase letter or digit.';
          Exit;
        end;
        if (c = '-') and ((AValue[i - 1] = '.') or (AValue[i + 1] = '.')) then
        begin
          AErr := 'Each part of the ' + AKind + ' must start and end with ' +
            'a lowercase letter or digit.';
          Exit;
        end;
      end;
      Continue;
    end;
    if AAllowDot then
      AErr := 'The ' + AKind + ' may contain only lowercase letters, ' +
        'digits, ''-'' and ''.''.'
    else
      AErr := 'The ' + AKind + ' may contain only lowercase letters, ' +
        'digits and ''-''.';
    Exit;
  end;
  Result := True;
end;

function ValidateK8sName(var AValue: string; out AErr: string): Boolean;
begin
  Result := ValidateK8sCore(AValue, True, 253, 'pod name', AErr);
end;

function ValidateK8sLabel(var AValue: string; out AErr: string): Boolean;
begin
  Result := ValidateK8sCore(AValue, False, 63, 'value', AErr);
end;

end.
