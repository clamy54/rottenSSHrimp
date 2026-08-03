unit uTermParser;

{$mode objfpc}{$H+}

// Parseur d'echappement terminal, machine a etats type VT500 (Paul Williams),
// incremental et borne en tout point: params CSI et
// chaines OSC plafonnes, DCS/SOS/PM/APC consommes sans accumulation, UTF-8
// invalide -> U+FFFD, sequence inconnue ignoree sans erreur.

interface

uses
  SysUtils, uTermTypes;

type
  // Recepteur des actions du parseur. Implemente par l'emulateur.
  TTermHandler = class
  public
    procedure Print(C: UCS4Char); virtual; abstract;
    procedure Execute(B: Byte); virtual; abstract; // controles C0
    procedure EscDispatch(const AInters: string; AFinal: Char); virtual; abstract;
    procedure CsiDispatch(const AParams: array of Integer; AParamCount: Integer;
      APrivate: Char; const AInters: string; AFinal: Char); virtual; abstract;
    procedure OscDispatch(const APayload: RawByteString); virtual; abstract;
  end;

  TParserState = (psGround, psEscape, psEscInter, psCsiEntry, psCsiParam,
    psCsiInter, psCsiIgnore, psOscString, psSkipString);

  TTermParser = class
  private
    FHandler: TTermHandler;
    FState: TParserState;
    // decodeur UTF-8 incremental
    FUtfAcc: Cardinal;
    FUtfNeed: Integer;
    FUtfMin: Cardinal;
    // collecte CSI
    FParams: array[0..TERM_MAX_CSI_PARAMS - 1] of Integer;
    FParamCount: Integer;
    FParamDigits: Boolean;
    FPrivate: Char;
    FInters: string;
    // collecte OSC
    FOsc: RawByteString;
    FOscOverflow: Boolean;
    FOscEsc: Boolean; // ESC vu, attend '\' (ST)
    procedure ResetCollect;
    procedure ToGround;
    procedure HandleCodepoint(C: UCS4Char);
    procedure HandleControl(B: Byte);
    procedure CsiCollectDigit(D: Integer);
    procedure CsiNextParam;
    procedure DispatchCsi(AFinal: Char);
    procedure DispatchOsc;
    procedure AppendOscUtf8(C: UCS4Char);
  public
    constructor Create(AHandler: TTermHandler);
    procedure Feed(const AData: PByte; ALen: SizeInt);
    procedure FeedStr(const AData: RawByteString);
    procedure Reset;
  end;

implementation

constructor TTermParser.Create(AHandler: TTermHandler);
begin
  inherited Create;
  FHandler := AHandler;
  Reset;
end;

procedure TTermParser.Reset;
begin
  FState := psGround;
  FUtfNeed := 0;
  FUtfAcc := 0;
  FUtfMin := 0;
  ResetCollect;
end;

procedure TTermParser.ResetCollect;
var
  i: Integer;
begin
  for i := 0 to TERM_MAX_CSI_PARAMS - 1 do
    FParams[i] := 0;
  FParamCount := 0;
  FParamDigits := False;
  FPrivate := #0;
  FInters := '';
  FOsc := '';
  FOscOverflow := False;
  FOscEsc := False;
end;

procedure TTermParser.ToGround;
begin
  FState := psGround;
  ResetCollect;
end;

procedure TTermParser.FeedStr(const AData: RawByteString);
begin
  if AData <> '' then
    Feed(PByte(PAnsiChar(AData)), Length(AData));
end;

procedure TTermParser.Feed(const AData: PByte; ALen: SizeInt);
var
  i: SizeInt;
  b: Byte;
begin
  for i := 0 to ALen - 1 do
  begin
    b := AData[i];

    // decodage UTF-8 incremental; les controles C0 court-circuitent
    if FUtfNeed > 0 then
    begin
      if (b and $C0) = $80 then
      begin
        FUtfAcc := (FUtfAcc shl 6) or (b and $3F);
        Dec(FUtfNeed);
        if FUtfNeed = 0 then
        begin
          // overlong, substituts, hors plage -> U+FFFD
          if (FUtfAcc < FUtfMin) or (FUtfAcc > $10FFFF) or
             ((FUtfAcc >= $D800) and (FUtfAcc <= $DFFF)) then
            FUtfAcc := $FFFD;
          HandleCodepoint(FUtfAcc);
        end;
        Continue;
      end;
      // sequence interrompue: U+FFFD puis retraite l'octet courant
      FUtfNeed := 0;
      HandleCodepoint($FFFD);
    end;

    if b < $80 then
    begin
      if b < $20 then
        HandleControl(b)
      else if b = $7F then
        // DEL: ignore en ground, mais octet valide dans OSC? Non: ignore.
        Continue
      else
        HandleCodepoint(UCS4Char(b));
    end
    else if (b and $E0) = $C0 then
    begin
      FUtfAcc := b and $1F;
      FUtfNeed := 1;
      FUtfMin := $80;
    end
    else if (b and $F0) = $E0 then
    begin
      FUtfAcc := b and $0F;
      FUtfNeed := 2;
      FUtfMin := $800;
    end
    else if (b and $F8) = $F0 then
    begin
      FUtfAcc := b and $07;
      FUtfNeed := 3;
      FUtfMin := $10000;
    end
    else
      HandleCodepoint($FFFD); // continuation orpheline ou octet invalide
  end;
end;

procedure TTermParser.HandleControl(B: Byte);
begin
  case B of
    $18, $1A: // CAN, SUB: abandon de la sequence en cours
      begin
        if FState <> psGround then
          ToGround;
        if B = $1A then
          FHandler.Execute(B);
      end;
    $1B: // ESC
      begin
        case FState of
          psOscString:
            begin
              FOscEsc := True; // peut etre ST (ESC \)
              Exit;
            end;
          psSkipString:
            begin
              FOscEsc := True;
              Exit;
            end;
        end;
        FState := psEscape;
        ResetCollect;
      end;
  else
    case FState of
      psOscString:
        ; // controles ignores dans OSC (BEL traite dans HandleCodepoint? non, ici)
      psSkipString:
        ;
    else
      FHandler.Execute(B); // C0 execute meme au milieu d'une sequence CSI
    end;
    if (B = $07) and (FState = psOscString) then
      DispatchOsc
    else if (B = $07) and (FState = psSkipString) then
      ToGround;
  end;
end;

procedure TTermParser.HandleCodepoint(C: UCS4Char);
begin
  case FState of
    psGround:
      FHandler.Print(C);

    psEscape:
      begin
        if FOscEsc then
          FOscEsc := False;
        if C = UCS4Char(Ord('[')) then
        begin
          FState := psCsiEntry;
          ResetCollect;
        end
        else if C = UCS4Char(Ord(']')) then
        begin
          FState := psOscString;
          ResetCollect;
        end
        else if (C = UCS4Char(Ord('P'))) or (C = UCS4Char(Ord('X'))) or
                (C = UCS4Char(Ord('^'))) or (C = UCS4Char(Ord('_'))) then
        begin
          FState := psSkipString; // DCS/SOS/PM/APC: consommes sans stockage
          ResetCollect;
        end
        else if (C >= $20) and (C <= $2F) then
        begin
          FInters := Chr(C);
          FState := psEscInter;
        end
        else if (C >= $30) and (C <= $7E) then
        begin
          FHandler.EscDispatch('', Chr(C));
          ToGround;
        end
        else
          ToGround; // >7E ou non-ASCII: abandon
      end;

    psEscInter:
      begin
        if (C >= $20) and (C <= $2F) then
        begin
          if Length(FInters) < TERM_MAX_INTERMEDIATES then
            FInters := FInters + Chr(C)
          else
            ToGround;
        end
        else if (C >= $30) and (C <= $7E) then
        begin
          FHandler.EscDispatch(FInters, Chr(C));
          ToGround;
        end
        else
          ToGround;
      end;

    psCsiEntry:
      begin
        if (C >= UCS4Char(Ord('0'))) and (C <= UCS4Char(Ord('9'))) then
        begin
          FState := psCsiParam;
          CsiCollectDigit(Integer(C) - Ord('0'));
        end
        else if (C = UCS4Char(Ord(';'))) or (C = UCS4Char(Ord(':'))) then
        begin
          FState := psCsiParam;
          CsiNextParam;
        end
        else if (C >= $3C) and (C <= $3F) then // < = > ?
        begin
          FPrivate := Chr(C);
          FState := psCsiParam;
        end
        else if (C >= $20) and (C <= $2F) then
        begin
          FInters := Chr(C);
          FState := psCsiInter;
        end
        else if (C >= $40) and (C <= $7E) then
          DispatchCsi(Chr(C))
        else
          ToGround;
      end;

    psCsiParam:
      begin
        if (C >= UCS4Char(Ord('0'))) and (C <= UCS4Char(Ord('9'))) then
          CsiCollectDigit(Integer(C) - Ord('0'))
        else if (C = UCS4Char(Ord(';'))) or (C = UCS4Char(Ord(':'))) then
          CsiNextParam
        else if (C >= $3C) and (C <= $3F) then
          FState := psCsiIgnore // marqueur prive hors position
        else if (C >= $20) and (C <= $2F) then
        begin
          FInters := Chr(C);
          FState := psCsiInter;
        end
        else if (C >= $40) and (C <= $7E) then
          DispatchCsi(Chr(C))
        else
          ToGround;
      end;

    psCsiInter:
      begin
        if (C >= $20) and (C <= $2F) then
        begin
          if Length(FInters) < TERM_MAX_INTERMEDIATES then
            FInters := FInters + Chr(C)
          else
            FState := psCsiIgnore;
        end
        else if (C >= $40) and (C <= $7E) then
          DispatchCsi(Chr(C))
        else if (C >= UCS4Char(Ord('0'))) and (C <= UCS4Char(Ord('?'))) then
          FState := psCsiIgnore
        else
          ToGround;
      end;

    psCsiIgnore:
      begin
        if (C >= $40) and (C <= $7E) then
          ToGround;
        // sinon: consomme sans effet
      end;

    psOscString:
      begin
        if FOscEsc then
        begin
          FOscEsc := False;
          if C = UCS4Char(Ord('\')) then // ST
          begin
            DispatchOsc;
            Exit;
          end;
          // ESC autre chose: abandonne l'OSC, retraite comme nouvelle sequence
          FState := psEscape;
          FOsc := '';
          FOscOverflow := False;
          HandleCodepoint(C);
          Exit;
        end;
        AppendOscUtf8(C);
      end;

    psSkipString:
      begin
        if FOscEsc then
        begin
          FOscEsc := False;
          if C = UCS4Char(Ord('\')) then
          begin
            ToGround;
            Exit;
          end;
          FState := psEscape;
          HandleCodepoint(C);
          Exit;
        end;
        // consomme sans stockage
      end;
  end;
end;

procedure TTermParser.CsiCollectDigit(D: Integer);
begin
  if FState = psCsiIgnore then
    Exit;
  if FParamCount = 0 then
    FParamCount := 1;
  if FParams[FParamCount - 1] < TERM_MAX_CSI_PARAM_VAL then
  begin
    FParams[FParamCount - 1] := FParams[FParamCount - 1] * 10 + D;
    if FParams[FParamCount - 1] > TERM_MAX_CSI_PARAM_VAL then
      FParams[FParamCount - 1] := TERM_MAX_CSI_PARAM_VAL;
  end;
  FParamDigits := True;
end;

procedure TTermParser.CsiNextParam;
begin
  if FParamCount = 0 then
    FParamCount := 1; // le param vide avant le separateur compte (valeur 0)
  if FParamCount >= TERM_MAX_CSI_PARAMS then
  begin
    FState := psCsiIgnore;
    Exit;
  end;
  FParams[FParamCount] := 0;
  Inc(FParamCount);
  FParamDigits := False;
end;

procedure TTermParser.DispatchCsi(AFinal: Char);
begin
  FHandler.CsiDispatch(FParams, FParamCount, FPrivate, FInters, AFinal);
  ToGround;
end;

procedure TTermParser.DispatchOsc;
begin
  FHandler.OscDispatch(FOsc);
  ToGround;
end;

procedure TTermParser.AppendOscUtf8(C: UCS4Char);
var
  s: RawByteString;
begin
  if FOscOverflow then
    Exit;
  s := CodepointToUtf8(C);   // encodeur unique (uTermTypes)
  if Length(FOsc) + Length(s) > TERM_MAX_OSC_LEN then
    FOscOverflow := True // l'excedent est jete, on attend le terminateur
  else
    FOsc := FOsc + s;
end;

end.
