{ Presse-papiers riche: texte, HTML, RTF, image. Ni LCL ni FreeRDP ici.
  Une image qui vient d'un serveur ne traverse JAMAIS telle quelle: elle est
  decodee en pixels, bornee, puis reencodee par nous. Le decodeur PNG d'en face
  n'a pas a payer pour celui du serveur.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipSnapshot;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  CLIP_RICH_MAX_BYTES = 16 * 1024 * 1024;
  // 8K UHD passe, de justesse; au-dela, la memoire d'un poste paie pour rien
  CLIP_IMAGE_MAX_SIDE = 16384;
  CLIP_IMAGE_MAX_PIXELS = 32 * 1024 * 1024;
  // un DIB 32 bits au plafond, en-tete et palette compris
  CLIP_IMAGE_MAX_BYTES = Int64(CLIP_IMAGE_MAX_PIXELS) * 4 + 64 * 1024;

type
  // BGRA en memoire, alpha non premultiplie, de haut en bas
  TClipImage = record
    Width, Height: Integer;
    Pixels: array of LongWord;
  end;

  { Une seule copie, plusieurs representations. Image: Png et/ou Dib, au moins
    un des deux; le transport fabrique l'autre a la demande. }
  TClipSnapshot = record
    Text: UnicodeString;
    Html: RawByteString;   // UTF-8, sans l'en-tete CF_HTML
    Rtf: RawByteString;
    Png: RawByteString;
    Dib: RawByteString;    // BITMAPINFO + pixels, sans BITMAPFILEHEADER
  end;

function ClipSnapshotEmpty(const S: TClipSnapshot): Boolean;
function ClipSnapshotHasImage(const S: TClipSnapshot): Boolean;
// Texte seul = le texte lui-meme, comme avant: VNC et RDP s'y reconnaissent.
function ClipSnapshotKey(const S: TClipSnapshot): string;

function CfHtmlWrap(const AHtml: RawByteString): RawByteString;
function CfHtmlUnwrap(const AData: RawByteString; out AHtml: RawByteString): Boolean;
// text/html de GTK et du Mac: UTF-8, ou UTF-16 avec ou sans BOM selon l'humeur
function HtmlToUtf8(const ARaw: RawByteString): RawByteString;
// RTF et HTML venus d'un serveur: sans images, objets, scripts ni
// instructions de champ. Les images passent par DibDecode/PngDecode,
// pas en contrebande dans un \pict ou un data:.
function RtfSane(const ARaw: RawByteString; out ARtf: RawByteString): Boolean;
function HtmlSane(const AHtml: RawByteString): RawByteString;

// APixOff >= 0: offset des pixels impose (BMP fichier), verifie quand meme
function DibDecode(AData: PByte; ALen: Int64; out AImg: TClipImage;
  out AWhy: string; APixOff: Int64 = -1): Boolean;
function DibEncode(const AImg: TClipImage): RawByteString;
function BmpFileDecode(const AData: RawByteString; out AImg: TClipImage;
  out AWhy: string): Boolean;
function PngDecode(const AData: RawByteString; out AImg: TClipImage;
  out AWhy: string): Boolean;
function PngEncode(const AImg: TClipImage): RawByteString;

implementation

uses
  Math, FPImage, FPReadPNG, FPWritePNG, ZStream;

function Fnv(const S: RawByteString): string;
var
  i: Integer;
  h: QWord;
begin
  h := QWord($cbf29ce484222325);
  for i := 1 to Length(S) do
    h := (h xor QWord(Byte(S[i]))) * QWord($100000001b3);
  Result := IntToHex(Int64(Length(S)), 8) + IntToHex(Int64(h), 16);
end;

function ClipSnapshotEmpty(const S: TClipSnapshot): Boolean;
begin
  Result := (S.Text = '') and (S.Html = '') and (S.Rtf = '') and
    not ClipSnapshotHasImage(S);
end;

function ClipSnapshotHasImage(const S: TClipSnapshot): Boolean;
begin
  Result := (S.Png <> '') or (S.Dib <> '');
end;

function ClipSnapshotKey(const S: TClipSnapshot): string;
begin
  Result := UTF8Encode(S.Text);
  if (S.Html = '') and (S.Rtf = '') and not ClipSnapshotHasImage(S) then
    Exit;
  Result := Result + #0'H' + Fnv(S.Html) + 'R' + Fnv(S.Rtf) + 'I';
  if S.Png <> '' then
    Result := Result + Fnv(S.Png)
  else
    Result := Result + Fnv(S.Dib);
end;

{ CF_HTML }

function CfHtmlWrap(const AHtml: RawByteString): RawByteString;
const
  HDR = 'Version:0.9'#13#10'StartHTML:%.10d'#13#10'EndHTML:%.10d'#13#10 +
    'StartFragment:%.10d'#13#10'EndFragment:%.10d'#13#10;
  MARK_START = '<!--StartFragment-->';
  MARK_END = '<!--EndFragment-->';
var
  body: RawByteString;
  hdrLen, fs, fe: Integer;
begin
  fs := Pos(MARK_START, AHtml);
  fe := Pos(MARK_END, AHtml);
  if (fs > 0) and (fe > fs) then
  begin
    body := AHtml;
    fs := fs - 1 + Length(MARK_START);
    fe := fe - 1;
  end
  else
  begin
    body := '<html><body>'#13#10 + MARK_START + AHtml + MARK_END +
      #13#10'</body></html>';
    fs := Length('<html><body>'#13#10 + MARK_START);
    fe := fs + Length(AHtml);
  end;
  hdrLen := Length(Format(HDR, [0, 0, 0, 0]));
  Result := Format(HDR, [hdrLen, hdrLen + Length(body), hdrLen + fs,
    hdrLen + fe]) + body;
end;

// -1 et absences tolerees, offsets hors donnees refuses: c'est le serveur qui compte
function CfHtmlUnwrap(const AData: RawByteString; out AHtml: RawByteString): Boolean;
var
  n, i, lineEnd: Integer;
  line, key, val: string;
  sh, eh, sf, ef, v: Int64;
begin
  Result := False;
  AHtml := '';
  n := Length(AData);
  while (n > 0) and (AData[n] = #0) do
    Dec(n);
  sh := -1; eh := -1; sf := -1; ef := -1;
  i := 1;
  while (i <= n) and (i < 4096) and (AData[i] <> '<') do
  begin
    lineEnd := i;
    while (lineEnd <= n) and not (AData[lineEnd] in [#13, #10]) do
      Inc(lineEnd);
    line := Copy(AData, i, lineEnd - i);
    v := Pos(':', line);
    if v > 0 then
    begin
      key := LowerCase(Trim(Copy(line, 1, v - 1)));
      val := Trim(Copy(line, v + 1, MaxInt));
      if key = 'starthtml' then sh := StrToInt64Def(val, -1)
      else if key = 'endhtml' then eh := StrToInt64Def(val, -1)
      else if key = 'startfragment' then sf := StrToInt64Def(val, -1)
      else if key = 'endfragment' then ef := StrToInt64Def(val, -1);
    end;
    i := lineEnd;
    while (i <= n) and (AData[i] in [#13, #10]) do
      Inc(i);
  end;
  if (sh >= 0) and (eh > sh) and (eh <= n) then
    AHtml := Copy(AData, sh + 1, eh - sh)
  else if (sf >= 0) and (ef > sf) and (ef <= n) then
    AHtml := Copy(AData, sf + 1, ef - sf)
  else
    Exit;
  Result := AHtml <> '';
end;

function HtmlToUtf8(const ARaw: RawByteString): RawByteString;
var
  u: UnicodeString;
  i, n, start: Integer;
  be: Boolean;
begin
  n := Length(ARaw);
  if (n >= 3) and (ARaw[1] = #$EF) and (ARaw[2] = #$BB) and (ARaw[3] = #$BF) then
    Exit(Copy(ARaw, 4, MaxInt));
  start := 1;
  be := False;
  if (n >= 2) and (ARaw[1] = #$FF) and (ARaw[2] = #$FE) then
    start := 3
  else if (n >= 2) and (ARaw[1] = #$FE) and (ARaw[2] = #$FF) then
  begin
    start := 3;
    be := True;
  end
  // sans BOM: un '<' suivi d'un NUL ne s'ecrit pas en UTF-8
  else if not ((n >= 2) and (ARaw[1] <> #0) and (ARaw[2] = #0)) then
    Exit(ARaw);
  SetLength(u, (n - start + 1) div 2);
  for i := 1 to Length(u) do
    if be then
      u[i] := WideChar(Byte(ARaw[start + 2 * (i - 1)]) shl 8 or
        Byte(ARaw[start + 2 * (i - 1) + 1]))
    else
      u[i] := WideChar(Byte(ARaw[start + 2 * (i - 1)]) or
        Byte(ARaw[start + 2 * (i - 1) + 1]) shl 8);
  i := Pos(#0, u);
  if i > 0 then
    SetLength(u, i - 1);
  Result := UTF8Encode(u);
end;

{ RTF: un tokeniseur juste assez grand pour savoir ou finit un groupe. \binN
  annonce N octets bruts qui peuvent contenir des accolades: on les saute,
  sinon le groupe fermerait au milieu d'une image. }

// a l'octet pres: pas de conversion de page de code dans le dos
function AsciiLower(const S: RawByteString): RawByteString;
var
  i: Integer;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function RtfWordAt(const S: RawByteString; I: Integer; out AWord: string;
  out AParam: Int64; out ANext: Integer): Boolean;
var
  j, n: Integer;
  neg: Boolean;
begin
  Result := False;
  AWord := '';
  AParam := -1;
  n := Length(S);
  ANext := I + 1;
  if (I >= n) or (S[I] <> '\') or not (S[I + 1] in ['a'..'z', 'A'..'Z']) then
    Exit;
  j := I + 1;
  while (j <= n) and (S[j] in ['a'..'z', 'A'..'Z']) and (j - I <= 32) do
    Inc(j);
  AWord := string(AsciiLower(Copy(S, I + 1, j - I - 1)));
  neg := (j <= n) and (S[j] = '-');
  if neg then Inc(j);
  if (j <= n) and (S[j] in ['0'..'9']) then
  begin
    AParam := 0;
    while (j <= n) and (S[j] in ['0'..'9']) do
    begin
      if AParam < 1000000000 then
        AParam := AParam * 10 + Ord(S[j]) - Ord('0');
      Inc(j);
    end;
    if neg then AParam := -AParam;
  end;
  if (j <= n) and (S[j] = ' ') then
    Inc(j);
  ANext := j;
  Result := True;
end;

// Index juste apres l'accolade fermante du groupe ouvert en I (ou fin).
function RtfSkipGroup(const S: RawByteString; I: Integer): Integer;
var
  depth, n, next: Integer;
  w: string;
  par: Int64;
begin
  n := Length(S);
  depth := 0;
  while I <= n do
  begin
    case S[I] of
      '\':
        if RtfWordAt(S, I, w, par, next) then
        begin
          I := next;
          if (w = 'bin') and (par > 0) then
            if par > n - I + 1 then I := n + 1 else Inc(I, Integer(par));
          Continue;
        end
        else
          Inc(I);   // \{ \} \\: le caractere echappe saute avec
      '{':
        Inc(depth);
      '}':
        begin
          Dec(depth);
          if depth <= 0 then
            Exit(I + 1);
        end;
    end;
    Inc(I);
  end;
  Result := n + 1;
end;

// Les instructions de champ partent toutes: seul le resultat affiche reste.
// Un lien redevient du texte, un numero de page garde sa derniere valeur, et
// plus rien ne va chercher ni lancer quoi que ce soit. Trier les « bons »
// champs voudrait dire lire le RTF exactement comme Word; quatre essais ont
// montre que non.
function RtfDropDest(const AWord: string): Boolean;
const
  DROP: array[0..11] of string = ('pict', 'shppict', 'nonshppict', 'object',
    'objdata', 'shp', 'shpinst', 'shpgrp', 'datastore', 'themedata',
    'colorschememapping', 'fldinst');
var
  d: string;
begin
  for d in DROP do
    if AWord = d then
      Exit(True);
  Result := False;
end;

function RtfStrip(const S: RawByteString): RawByteString;
var
  i, j, n, o, next: Integer;
  w: string;
  par: Int64;

  procedure Emit(AFrom, ACount: Integer);
  begin
    if ACount <= 0 then Exit;
    Move(S[AFrom], Result[o + 1], ACount);
    Inc(o, ACount);
  end;

  // Les lecteurs ignorent CR/LF, et RichEdit passe meme sur une espace
  // devant \pict. Le tamis regarde donc par-dessus les deux.
  procedure SkipBlank(var K: Integer);
  begin
    while (K <= n) and (S[K] in [#13, #10, ' ', #9]) do
      Inc(K);
  end;

  // Un groupe retire au milieu d'un mot de controle recollerait les deux
  // moities: \pi{...}ct deviendrait \pict. L'espace qui le clot est avalee
  // par les lecteurs, elle n'ajoute rien au texte.
  procedure CloseControlWord;
  var
    k, m: Integer;
  begin
    // rien a recoller si la suite ne peut pas prolonger le mot
    if (i > n) or not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '-']) then
      Exit;
    // un mot de controle tient en quelques dizaines de caracteres: plus loin,
    // c'est du texte, et le remonter a chaque retrait serait quadratique
    k := o;
    while (k > 0) and (o - k <= 64) and
          (Result[k] in ['a'..'z', 'A'..'Z', '0'..'9', '-']) do
      Dec(k);
    if (k = o) or (k = 0) or (Result[k] <> '\') then
      Exit;
    m := k;
    while (m > 0) and (Result[m] = '\') do
      Dec(m);
    if Odd(k - m) then
    begin
      Inc(o);
      Result[o] := ' ';
    end;
  end;

begin
  n := Length(S);
  SetLength(Result, n);   // on ne fait que retirer
  o := 0;
  i := 1;
  while i <= n do
    case S[i] of
      '{':
        begin
          j := i + 1;
          SkipBlank(j);
          // \*\*\pict reste un \pict pour l'editeur: on saute TOUS les \*
          while (j < n) and (S[j] = '\') and (S[j + 1] = '*') do
          begin
            Inc(j, 2);
            SkipBlank(j);
          end;
          // un groupe n'est parcouru que pour etre jete: lineaire
          if RtfWordAt(S, j, w, par, next) and RtfDropDest(w) then
          begin
            i := RtfSkipGroup(S, i);
            CloseControlWord;
            Continue;
          end;
          Emit(i, 1);
          Inc(i);
        end;
      '\':
        if RtfWordAt(S, i, w, par, next) then
        begin
          if (w = 'bin') and (par > 0) then
            next := next + Integer(Min(par, Int64(n - next + 1)));
          Emit(i, next - i);
          i := next;
        end
        else
        begin
          Emit(i, Min(2, n - i + 1));
          Inc(i, 2);
        end;
    else
      Emit(i, 1);
      Inc(i);
    end;
  SetLength(Result, o);
end;

function RtfSane(const ARaw: RawByteString; out ARtf: RawByteString): Boolean;
var
  n: Integer;
  raw: RawByteString;
begin
  n := Pos(#0, ARaw);
  if n > 0 then
    ARtf := Copy(ARaw, 1, n - 1)
  else
    ARtf := ARaw;
  Result := Copy(ARtf, 1, 5) = '{\rtf';
  if not Result then
  begin
    ARtf := '';
    Exit;
  end;
  // Retirer un groupe peut en faire apparaitre un autre ({{...}\pict): on
  // repasse jusqu'a ce que plus rien ne parte. Toujours en mouvement apres
  // quelques tours, ce n'est plus du RTF, c'est un piege: rien ne passe.
  for n := 1 to 8 do
  begin
    raw := RtfStrip(ARtf);
    if raw = ARtf then
      Exit;
    ARtf := raw;
  end;
  ARtf := '';
  Result := False;
end;

{ HTML: une liste blanche, pas une liste noire. Chaque balise gardee est
  RECONSTRUITE avec les seuls attributs de mise en forme connus; le reste
  part, contenu texte excepte. Une liste noire perd toujours la course contre
  le prochain attribut qui va chercher une image ailleurs. }

const
  HTML_KEEP: array[0..57] of string = ('html', 'head', 'body', 'title', 'div',
    'span', 'p', 'br', 'hr', 'b', 'strong', 'i', 'em', 'u', 's', 'strike',
    'del', 'ins', 'sub', 'sup', 'small', 'big', 'font', 'center', 'tt', 'code',
    'kbd', 'samp', 'var', 'cite', 'q', 'abbr', 'mark', 'pre', 'blockquote',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'dl', 'dt', 'dd',
    'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'col', 'colgroup',
    'caption', 'a');
  // partent AVEC leur contenu: du code, des donnees, ou les deux
  HTML_DROP_BLOCK: array[0..10] of string = ('script', 'iframe', 'object',
    'svg', 'math', 'noscript', 'template', 'frameset', 'applet', 'xml',
    'textarea');
  HTML_ATTRS: array[0..18] of string = ('style', 'class', 'id', 'title',
    'lang', 'dir', 'align', 'valign', 'width', 'height', 'border',
    'cellpadding', 'cellspacing', 'colspan', 'rowspan', 'span', 'color',
    'face', 'size');

function HtmlInList(const AName: string; const AList: array of string): Boolean;
var
  x: string;
begin
  for x in AList do
    if AName = x then
      Exit(True);
  Result := False;
end;

// CSS sans rien qui charge, execute ou s'echappe; sinon on jette le bloc.
function CssSafe(const ACss: RawByteString): Boolean;
const
  BAD: array[0..8] of string = ('url', 'expression', 'import', 'image',
    'behavior', 'binding', 'javascript', '\', '&');
var
  low: RawByteString;
  b: string;
begin
  low := AsciiLower(ACss);
  for b in BAD do
    if Pos(b, low) > 0 then
      Exit(False);
  Result := True;
end;

function HrefSafe(const AValue: RawByteString): Boolean;
var
  low: RawByteString;
  c, sl: Integer;
begin
  low := AsciiLower(Trim(AValue));
  c := Pos(':', low);
  sl := Pos('/', low);
  // relatif ou ancre: pas de schema avant le premier '/'
  if (c = 0) or ((sl > 0) and (sl < c)) then
    Exit(True);
  Result := (Copy(low, 1, 5) = 'http:') or (Copy(low, 1, 6) = 'https:') or
    (Copy(low, 1, 7) = 'mailto:');
end;

// Valeur reecrite entre guillemets: entites, echappements et caracteres de
// controle n'y entrent pas, ils servent surtout a deguiser un schema.
function AttrValueSafe(const AName, AValue: RawByteString): Boolean;
var
  k: Integer;
begin
  for k := 1 to Length(AValue) do
    if (AValue[k] < ' ') or (AValue[k] in ['"', '\', '<', '>']) then
      Exit(False);
  k := Pos('&', AValue);
  while k > 0 do
  begin
    if Copy(AValue, k, 5) <> '&amp;' then
      Exit(False);
    k := Pos('&', AValue, k + 1);
  end;
  if AName = 'style' then
    Result := CssSafe(AValue)
  else if AName = 'href' then
    Result := HrefSafe(AValue)
  else
    Result := True;
end;

function HtmlSane(const AHtml: RawByteString): RawByteString;
var
  low, name, aname, aval, rebuilt: RawByteString;
  i, j, n, k, a0, outLen, endc, nextEnd, nextBang: Integer;
  closing: Boolean;
  q: AnsiChar;

  procedure Put(const X: RawByteString);
  begin
    if X = '' then Exit;
    if outLen + Length(X) > Length(Result) then
      SetLength(Result, 2 * (outLen + Length(X)));
    Move(X[1], Result[outLen + 1], Length(X));
    Inc(outLen, Length(X));
  end;

  // fin de balise hors guillemets, ou 0
  function TagEnd(AFrom: Integer): Integer;
  var
    qq: AnsiChar;
  begin
    qq := #0;
    while AFrom <= n do
    begin
      if qq <> #0 then
      begin
        if AHtml[AFrom] = qq then qq := #0;
      end
      else if AHtml[AFrom] in ['"', #39] then
        qq := AHtml[AFrom]
      else if AHtml[AFrom] = '>' then
        Exit(AFrom);
      Inc(AFrom);
    end;
    Result := 0;
  end;

begin
  n := Length(AHtml);
  low := AsciiLower(AHtml);
  Result := '';
  SetLength(Result, n);
  outLen := 0;
  nextEnd := 0;
  nextBang := 0;
  i := 1;
  while i <= n do
  begin
    if AHtml[i] <> '<' then
    begin
      j := Pos('<', AHtml, i);
      if j = 0 then j := n + 1;
      Put(Copy(AHtml, i, j - i));
      i := j;
      Continue;
    end;
    // commentaire: ferme par --> ou --!>, comme le font les navigateurs;
    // seuls les reperes de fragment survivent
    if Copy(AHtml, i, 4) = '<!--' then
    begin
      // prochaines fins memorisees: chercher depuis chaque commentaire jusqu'au
      // bout du texte serait quadratique
      if (nextEnd >= 0) and (nextEnd < i + 4) then
      begin
        nextEnd := Pos('-->', AHtml, i + 4);
        if nextEnd = 0 then nextEnd := -1;
      end;
      if (nextBang >= 0) and (nextBang < i + 4) then
      begin
        nextBang := Pos('--!>', AHtml, i + 4);
        if nextBang = 0 then nextBang := -1;
      end;
      j := Max(nextEnd, 0);
      k := Max(nextBang, 0);
      if (k > 0) and ((j = 0) or (k < j)) then
      begin
        name := Trim(Copy(AHtml, i + 4, k - i - 4));
        endc := k + 4;
      end
      else if j > 0 then
      begin
        name := Trim(Copy(AHtml, i + 4, j - i - 4));
        endc := j + 3;
      end
      else
        Break;
      if (name = 'StartFragment') or (name = 'EndFragment') then
        Put('<!--' + name + '-->');
      i := endc;
      Continue;
    end;
    // <!DOCTYPE>, <?xml?>: rien a garder
    if (i < n) and (AHtml[i + 1] in ['!', '?']) then
    begin
      k := TagEnd(i + 1);
      if k = 0 then Break;
      i := k + 1;
      Continue;
    end;
    j := i + 1;
    closing := (j <= n) and (AHtml[j] = '/');
    if closing then Inc(j);
    k := j;
    while (k <= n) and (low[k] in ['a'..'z', '0'..'9']) do
      Inc(k);
    name := Copy(low, j, k - j);
    if name = '' then
    begin
      Put('&lt;');
      Inc(i);
      Continue;
    end;
    j := TagEnd(k);
    if j = 0 then
      Break;   // balise jamais fermee: la suite n'est que ruine
    if closing then
    begin
      if HtmlInList(string(name), HTML_KEEP) then
        Put('</' + name + '>');
      i := j + 1;
      Continue;
    end;
    if HtmlInList(string(name), HTML_DROP_BLOCK) or (name = 'style') then
    begin
      k := Pos('</' + name, low, j + 1);
      if k = 0 then
        Break;
      if (name = 'style') and CssSafe(Copy(AHtml, j + 1, k - j - 1)) then
        Put('<style>' + Copy(AHtml, j + 1, k - j - 1) + '</style>');
      i := TagEnd(k);
      if i = 0 then Break;
      Inc(i);
      Continue;
    end;
    i := j + 1;
    if not HtmlInList(string(name), HTML_KEEP) then
      Continue;   // inconnue: la balise part, son texte reste
    rebuilt := '<' + name;
    while k < j do
    begin
      while (k < j) and (AHtml[k] in [' ', #9, #10, #13, '/']) do
        Inc(k);
      if k >= j then Break;
      a0 := k;
      while (k < j) and not (AHtml[k] in [' ', #9, #10, #13, '=', '/']) do
        Inc(k);
      aname := Copy(low, a0, k - a0);
      while (k < j) and (AHtml[k] in [' ', #9, #10, #13]) do
        Inc(k);
      aval := '';
      if (k < j) and (AHtml[k] = '=') then
      begin
        Inc(k);
        while (k < j) and (AHtml[k] in [' ', #9, #10, #13]) do
          Inc(k);
        if (k < j) and (AHtml[k] in ['"', #39]) then
        begin
          q := AHtml[k];
          Inc(k);
          a0 := k;
          while (k < j) and (AHtml[k] <> q) do
            Inc(k);
          aval := Copy(AHtml, a0, k - a0);
          Inc(k);
        end
        else
        begin
          a0 := k;
          while (k < j) and not (AHtml[k] in [' ', #9, #10, #13]) do
            Inc(k);
          aval := Copy(AHtml, a0, k - a0);
        end;
      end;
      if aname = '' then
        Inc(k)
      else if (HtmlInList(string(aname), HTML_ATTRS) or
               ((aname = 'href') and (name = 'a'))) and
              AttrValueSafe(aname, aval) then
        rebuilt := rebuilt + ' ' + aname + '="' + aval + '"';
    end;
    Put(rebuilt + '>');
  end;
  SetLength(Result, outLen);
end;

{ DIB }

const
  BI_RGB = 0;
  BI_BITFIELDS = 3;
  BI_ALPHABITFIELDS = 6;

function Le16(P: PByte): Word; inline;
begin
  Result := P[0] or (Word(P[1]) shl 8);
end;

function Le32(P: PByte): LongWord; inline;
begin
  Result := P[0] or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or
    (LongWord(P[3]) shl 24);
end;

type
  TMaskChan = record
    Mask: LongWord;
    Shift, Bits: Integer;
  end;

function MaskChan(AMask: LongWord): TMaskChan;
begin
  Result.Mask := AMask;
  Result.Shift := 0;
  Result.Bits := 0;
  if AMask = 0 then Exit;
  while (AMask and 1) = 0 do
  begin
    AMask := AMask shr 1;
    Inc(Result.Shift);
  end;
  while (AMask and 1) = 1 do
  begin
    AMask := AMask shr 1;
    Inc(Result.Bits);
  end;
end;

function ChanValue(const C: TMaskChan; V: LongWord; ADefault: Byte): Byte; inline;
var
  x: LongWord;
begin
  if C.Bits = 0 then Exit(ADefault);
  x := (V and C.Mask) shr C.Shift;
  if C.Bits >= 8 then
    Result := Byte(x shr (C.Bits - 8))
  else
    Result := Byte(x * 255 div ((LongWord(1) shl C.Bits) - 1));
end;

function Bgra(B, G, R, A: Byte): LongWord; inline;
begin
  Result := B or (LongWord(G) shl 8) or (LongWord(R) shl 16) or
    (LongWord(A) shl 24);
end;

// Tout ce qui est lu est d'abord compte contre ALen: le DIB vient d'en face.
function DibDecode(AData: PByte; ALen: Int64; out AImg: TClipImage;
  out AWhy: string; APixOff: Int64): Boolean;
var
  hdr, bpp, comp, nPal, i, x, y, row, w, h, a: Integer;
  planes: Word;
  hh: LongInt;
  topDown, anyAlpha: Boolean;
  stride, off, need: Int64;
  pal: array[0..255] of LongWord;
  cr, cg, cb, ca: TMaskChan;
  src: PByte;
  v: LongWord;
  idx: Byte;
begin
  Result := False;
  AImg := Default(TClipImage);
  AWhy := '';
  if (AData = nil) or (ALen < 40) then
  begin
    AWhy := 'truncated header';
    Exit;
  end;
  hdr := Integer(Le32(AData));
  if not ((hdr = 40) or (hdr = 52) or (hdr = 56) or (hdr = 108) or
          (hdr = 124)) or (hdr > ALen) then
  begin
    AWhy := 'unknown header';
    Exit;
  end;
  w := LongInt(Le32(AData + 4));
  hh := LongInt(Le32(AData + 8));
  planes := Le16(AData + 12);
  bpp := Le16(AData + 14);
  comp := Integer(Le32(AData + 16));
  nPal := Integer(Le32(AData + 32));
  if (planes <> 1) or (hh = Low(LongInt)) or (hh = 0) or (w <= 0) then
  begin
    AWhy := 'bad geometry';
    Exit;
  end;
  topDown := hh < 0;
  h := Abs(hh);
  if (w > CLIP_IMAGE_MAX_SIDE) or (h > CLIP_IMAGE_MAX_SIDE) or
     (Int64(w) * h > CLIP_IMAGE_MAX_PIXELS) then
  begin
    AWhy := Format('too large (%dx%d)', [w, h]);
    Exit;
  end;

  off := hdr;
  cr := MaskChan(0); cg := cr; cb := cr; ca := cr;
  case bpp of
    1, 4, 8:
      begin
        if comp <> BI_RGB then
        begin
          AWhy := 'compressed palette image';
          Exit;
        end;
        if (nPal <= 0) or (nPal > 1 shl bpp) then
          nPal := 1 shl bpp;
        if off + Int64(nPal) * 4 > ALen then
        begin
          AWhy := 'truncated palette';
          Exit;
        end;
        FillChar(pal, SizeOf(pal), 0);
        for i := 0 to nPal - 1 do
          pal[i] := Le32(AData + off + i * 4) or $FF000000;
        off := off + Int64(nPal) * 4;
      end;
    16, 32:
      if comp = BI_RGB then
      begin
        if bpp = 16 then
        begin
          cr := MaskChan($7C00); cg := MaskChan($03E0); cb := MaskChan($001F);
        end
        else
        begin
          cr := MaskChan($00FF0000); cg := MaskChan($0000FF00);
          cb := MaskChan($000000FF); ca := MaskChan($FF000000);
        end;
      end
      else if (comp = BI_BITFIELDS) or (comp = BI_ALPHABITFIELDS) then
      begin
        // en-tete 40: les masques le SUIVENT; V2 et plus: ils sont DEDANS
        if hdr = 40 then
        begin
          i := 12;
          if comp = BI_ALPHABITFIELDS then i := 16;
          if off + i > ALen then
          begin
            AWhy := 'truncated masks';
            Exit;
          end;
          cr := MaskChan(Le32(AData + 40));
          cg := MaskChan(Le32(AData + 44));
          cb := MaskChan(Le32(AData + 48));
          if comp = BI_ALPHABITFIELDS then
            ca := MaskChan(Le32(AData + 52));
          off := off + i;
        end
        else
        begin
          cr := MaskChan(Le32(AData + 40));
          cg := MaskChan(Le32(AData + 44));
          cb := MaskChan(Le32(AData + 48));
          if hdr >= 56 then
            ca := MaskChan(Le32(AData + 52));
        end;
      end
      else
      begin
        AWhy := 'unsupported compression';
        Exit;
      end;
    24:
      if comp <> BI_RGB then
      begin
        AWhy := 'unsupported compression';
        Exit;
      end;
  else
    AWhy := Format('unsupported depth (%d bits)', [bpp]);
    Exit;
  end;

  if APixOff >= 0 then
  begin
    if APixOff < off then
    begin
      AWhy := 'pixels overlap the header';
      Exit;
    end;
    off := APixOff;
  end;
  stride := ((Int64(w) * bpp + 31) div 32) * 4;
  need := off + stride * h;
  if need > ALen then
  begin
    AWhy := 'truncated pixels';
    Exit;
  end;

  AImg.Width := w;
  AImg.Height := h;
  SetLength(AImg.Pixels, w * h);
  anyAlpha := False;
  for y := 0 to h - 1 do
  begin
    if topDown then row := y else row := h - 1 - y;
    src := AData + off + stride * row;
    for x := 0 to w - 1 do
    begin
      case bpp of
        1, 4, 8:
          begin
            if bpp = 8 then
              idx := src[x]
            else if bpp = 4 then
              idx := (src[x shr 1] shr (4 * (1 - (x and 1)))) and $0F
            else
              idx := (src[x shr 3] shr (7 - (x and 7))) and 1;
            if idx < nPal then
              v := pal[idx]
            else
              v := $FF000000;
          end;
        16:
          begin
            i := Le16(src + 2 * x);
            v := Bgra(ChanValue(cb, i, 0), ChanValue(cg, i, 0),
              ChanValue(cr, i, 0), 255);
          end;
        24:
          v := Bgra(src[3 * x], src[3 * x + 1], src[3 * x + 2], 255);
      else
        begin
          i := Integer(Le32(src + 4 * x));
          a := ChanValue(ca, LongWord(i), 255);
          if (ca.Bits > 0) and (a <> 0) then
            anyAlpha := True;
          v := Bgra(ChanValue(cb, LongWord(i), 0), ChanValue(cg, LongWord(i), 0),
            ChanValue(cr, LongWord(i), 0), a);
        end;
      end;
      AImg.Pixels[y * w + x] := v;
    end;
  end;
  // 32 bits: l'alpha est souvent un octet de bourrage laisse a zero, masque
  // annonce ou pas. Une image entierement transparente ne vaut pas d'etre
  // copiee; une capture rendue invisible, si, d'etre evitee.
  if (bpp = 32) and (ca.Bits > 0) and not anyAlpha then
    for i := 0 to High(AImg.Pixels) do
      AImg.Pixels[i] := AImg.Pixels[i] or $FF000000;
  Result := True;
end;

procedure Put32(var S: RawByteString; AOff: Integer; V: LongWord); inline;
begin
  S[AOff + 1] := AnsiChar(V and $FF);
  S[AOff + 2] := AnsiChar((V shr 8) and $FF);
  S[AOff + 3] := AnsiChar((V shr 16) and $FF);
  S[AOff + 4] := AnsiChar((V shr 24) and $FF);
end;

// 32 bits BI_RGB de bas en haut: ce que tout lecteur de DIB accepte encore
function DibEncode(const AImg: TClipImage): RawByteString;
var
  y, rowBytes: Integer;
begin
  Result := '';
  if (AImg.Width <= 0) or (AImg.Height <= 0) or
     (Length(AImg.Pixels) < AImg.Width * AImg.Height) then
    Exit;
  rowBytes := AImg.Width * 4;
  SetLength(Result, 40 + rowBytes * AImg.Height);
  FillChar(Result[1], 40, 0);
  Put32(Result, 0, 40);
  Put32(Result, 4, LongWord(AImg.Width));
  Put32(Result, 8, LongWord(AImg.Height));
  Result[13] := #1;
  Result[15] := #32;
  Put32(Result, 20, LongWord(rowBytes * AImg.Height));
  for y := 0 to AImg.Height - 1 do
    Move(AImg.Pixels[(AImg.Height - 1 - y) * AImg.Width],
      Result[41 + y * rowBytes], rowBytes);
end;

function BmpFileDecode(const AData: RawByteString; out AImg: TClipImage;
  out AWhy: string): Boolean;
var
  bits: Int64;
begin
  AImg := Default(TClipImage);
  if (Length(AData) < 14 + 40) or (AData[1] <> 'B') or (AData[2] <> 'M') then
  begin
    AWhy := 'not a BMP file';
    Exit(False);
  end;
  // bfOffBits compte depuis le debut du fichier, le DIB commence apres 14
  bits := Int64(Le32(PByte(@AData[11]))) - 14;
  if (bits < 40) or (bits >= Length(AData) - 14) then
  begin
    AWhy := 'bad pixel offset';
    Exit(False);
  end;
  Result := DibDecode(PByte(@AData[15]), Length(AData) - 14, AImg, AWhy, bits);
end;

{ PNG }

type
  // Pixels poses directement dans le TClipImage: pas de copie 16 bits par canal
  TClipPixelImage = class(TFPCustomImage)
  private
    FImg: TClipImage;
  protected
    procedure SetInternalColor(x, y: Integer; const Value: TFPColor); override;
    function GetInternalColor(x, y: Integer): TFPColor; override;
    procedure SetInternalPixel(x, y: Integer; Value: Integer); override;
    function GetInternalPixel(x, y: Integer): Integer; override;
  public
    procedure SetSize(AWidth, AHeight: Integer); override;
  end;

procedure TClipPixelImage.SetSize(AWidth, AHeight: Integer);
begin
  if (AWidth < 0) or (AHeight < 0) or (AWidth > CLIP_IMAGE_MAX_SIDE) or
     (AHeight > CLIP_IMAGE_MAX_SIDE) or
     (Int64(AWidth) * AHeight > CLIP_IMAGE_MAX_PIXELS) then
    raise EInvalidOperation.Create('image too large');
  inherited SetSize(AWidth, AHeight);
  FImg.Width := AWidth;
  FImg.Height := AHeight;
  FImg.Pixels := nil;
  SetLength(FImg.Pixels, AWidth * AHeight);
end;

procedure TClipPixelImage.SetInternalColor(x, y: Integer; const Value: TFPColor);
begin
  FImg.Pixels[y * FImg.Width + x] := Bgra(Value.Blue shr 8, Value.Green shr 8,
    Value.Red shr 8, Value.Alpha shr 8);
end;

function TClipPixelImage.GetInternalColor(x, y: Integer): TFPColor;
var
  v: LongWord;
begin
  v := FImg.Pixels[y * FImg.Width + x];
  Result.Blue := (v and $FF) * $101;
  Result.Green := ((v shr 8) and $FF) * $101;
  Result.Red := ((v shr 16) and $FF) * $101;
  Result.Alpha := ((v shr 24) and $FF) * $101;
end;

procedure TClipPixelImage.SetInternalPixel(x, y: Integer; Value: Integer);
begin
end;

function TClipPixelImage.GetInternalPixel(x, y: Integer): Integer;
begin
  Result := 0;
end;

function BE32(const S: RawByteString; AOff: Integer): LongWord;
begin
  Result := (LongWord(Byte(S[AOff])) shl 24) or (LongWord(Byte(S[AOff + 1])) shl 16)
    or (LongWord(Byte(S[AOff + 2])) shl 8) or Byte(S[AOff + 3]);
end;

// Le decodeur de FPC croit la longueur des blocs sur parole: IHDR de 8
// octets lu sur 13, bloc qui annonce 2 Gio alloue avant d'etre lu. Tout le
// cadrage est donc verifie ici, a la main, avant de lui confier quoi que ce
// soit. Les dimensions aussi: 30 octets peuvent reclamer des gigaoctets.
const
  ADAM_X0: array[0..6] of Integer = (0, 4, 0, 2, 0, 1, 0);
  ADAM_Y0: array[0..6] of Integer = (0, 0, 4, 0, 2, 0, 1);
  ADAM_DX: array[0..6] of Integer = (8, 8, 4, 4, 2, 2, 1);
  ADAM_DY: array[0..6] of Integer = (8, 8, 8, 4, 4, 2, 2);

// Le decodeur de FPC croit le flux zlib sur parole: trop court, il lit un
// tampon jamais initialise; un filtre de ligne inconnu, il calcule avec une
// variable jamais initialisee. Dans les deux cas, des octets de notre memoire
// deviendraient des pixels. On decompresse donc une fois, sous plafond, en
// exigeant le compte exact de lignes et un filtre 0..4 en tete de chacune.
function PngIdatSane(AIdat: TMemoryStream; AW, AH: LongWord; ABits: Integer;
  AInterlaced: Boolean): Boolean;
var
  z: TDecompressionStream;
  buf: array[0..65535] of Byte;
  got, k, take: Integer;
  pass, rowsLeft: Integer;
  rowLen, inRow: Int64;

  // Ligne suivante, passe Adam7 suivante au besoin; False quand tout est lu.
  function NextRow: Boolean;
  var
    pw, ph: Int64;
  begin
    while rowsLeft = 0 do
    begin
      Inc(pass);
      if (not AInterlaced and (pass > 0)) or (pass > 6) then
        Exit(False);
      if AInterlaced then
      begin
        pw := (Int64(AW) - ADAM_X0[pass] + ADAM_DX[pass] - 1) div ADAM_DX[pass];
        ph := (Int64(AH) - ADAM_Y0[pass] + ADAM_DY[pass] - 1) div ADAM_DY[pass];
      end
      else
      begin
        pw := AW;
        ph := AH;
      end;
      if (pw > 0) and (ph > 0) then
      begin
        rowsLeft := ph;
        rowLen := 1 + (pw * ABits + 7) div 8;
      end;
    end;
    Dec(rowsLeft);
    inRow := 0;
    Result := True;
  end;

begin
  Result := False;
  AIdat.Position := 0;
  pass := -1;
  rowsLeft := 0;
  rowLen := 0;
  inRow := 0;
  if not NextRow then
    Exit;
  z := TDecompressionStream.Create(AIdat);
  try
    try
      repeat
        got := z.Read(buf, SizeOf(buf));
        k := 0;
        while k < got do
        begin
          if inRow = rowLen then
            if not NextRow then
              Exit;   // plus long que l'image: bombe ou mensonge, meme reponse
          if (inRow = 0) and (buf[k] > 4) then
            Exit;
          take := got - k;
          if take > rowLen - inRow then
            take := Integer(rowLen - inRow);
          Inc(inRow, take);
          Inc(k, take);
        end;
      until got = 0;
      // fini pile a la fin de la derniere ligne, et plus aucune a venir
      Result := (inRow = rowLen) and not NextRow;
    except
      Result := False;
    end;
  finally
    z.Free;
  end;
end;

function PngFraming(const AData: RawByteString; out AW, AH: LongWord;
  out AWhy: string): Boolean;
const
  SIG = #137'PNG'#13#10#26#10;
  CHANNELS: array[0..6] of Integer = (1, 0, 3, 1, 2, 0, 4);
var
  pos, n, chunks: Int64;
  len: LongWord;
  kind, seen: string;
  depth, color, k: Integer;
  ok, ended, interlaced: Boolean;
  idat: TMemoryStream;
begin
  Result := False;
  AW := 0;
  AH := 0;
  n := Length(AData);
  if (n < 8 + 25) or (Copy(AData, 1, 8) <> SIG) then
  begin
    AWhy := 'not a PNG';
    Exit;
  end;
  pos := 9;
  chunks := 0;
  ended := False;
  seen := '';
  depth := 0;
  color := 0;
  interlaced := False;
  idat := TMemoryStream.Create;
  try
    while pos + 12 - 1 <= n do
    begin
      len := BE32(AData, pos);
      kind := Copy(AData, pos + 4, 4);
      for k := 1 to 4 do
        if not (kind[k] in ['a'..'z', 'A'..'Z']) then
        begin
          AWhy := 'corrupt PNG chunk';
          Exit;
        end;
      if (len > $7FFFFFFF) or (pos + 12 + Int64(len) - 1 > n) then
      begin
        AWhy := 'truncated PNG chunk';
        Exit;
      end;
      if chunks = 0 then
      begin
        if (kind <> 'IHDR') or (len <> 13) then
        begin
          AWhy := 'not a PNG';
          Exit;
        end;
        AW := BE32(AData, pos + 8);
        AH := BE32(AData, pos + 12);
        depth := Byte(AData[pos + 16]);
        color := Byte(AData[pos + 17]);
        case color of
          0: ok := depth in [1, 2, 4, 8, 16];
          3: ok := depth in [1, 2, 4, 8];
          2, 4, 6: ok := depth in [8, 16];
        else
          ok := False;
        end;
        interlaced := AData[pos + 20] = #1;
        if not ok or (AData[pos + 18] <> #0) or (AData[pos + 19] <> #0) or
           (Byte(AData[pos + 20]) > 1) then
        begin
          AWhy := 'unsupported PNG';
          Exit;
        end;
        if (AW = 0) or (AH = 0) or (AW > CLIP_IMAGE_MAX_SIDE) or
           (AH > CLIP_IMAGE_MAX_SIDE) or (QWord(AW) * AH > CLIP_IMAGE_MAX_PIXELS) then
        begin
          AWhy := Format('too large (%dx%d)', [AW, AH]);
          Exit;
        end;
      end;
      // un bloc en double n'a rien a faire la, et le decodeur de FPC perd sa
      // palette precedente a chaque PLTE: une fuite par image
      // PLTE et tRNS bornes par la norme: le decodeur de FPC alloue ce que le
      // bloc annonce
      if (kind = 'PLTE') and ((len mod 3 <> 0) or (len = 0) or (len > 768) or
         (color in [0, 4]) or ((color = 3) and (len div 3 > 1 shl depth))) then
      begin
        AWhy := 'bad PNG palette';
        Exit;
      end;
      if (kind = 'tRNS') and (((color = 0) and (len <> 2)) or
         ((color = 2) and (len <> 6)) or ((color = 3) and (len > 256)) or
         (color in [4, 6])) then
      begin
        AWhy := 'bad PNG transparency';
        Exit;
      end;
      if kind = 'IDAT' then
        idat.WriteBuffer(AData[pos + 8], len)
      else if System.Pos('|' + kind, seen) > 0 then
      begin
        AWhy := 'duplicate PNG chunk';
        Exit;
      end
      else
        seen := seen + '|' + kind;
      // Des IDAT par milliers, c'est un gros PNG; des blocs annexes par
      // milliers, c'est quelqu'un qui compte sur la recherche de doublons.
      Inc(chunks);
      if (chunks > 100000) or (Length(seen) > 64 * 5) then
      begin
        AWhy := 'too many PNG chunks';
        Exit;
      end;
      pos := pos + 12 + len;
      if kind = 'IEND' then
      begin
        ended := True;
        Break;
      end;
    end;
    if not ended then
    begin
      AWhy := 'truncated PNG';
      Exit;
    end;
    if not PngIdatSane(idat, AW, AH, CHANNELS[color] * depth, interlaced) then
    begin
      AWhy := 'image data does not match its size';
      Exit;
    end;
    Result := True;
  finally
    idat.Free;
  end;
end;

function PngDecode(const AData: RawByteString; out AImg: TClipImage;
  out AWhy: string): Boolean;
var
  w, h: LongWord;
  ms: TMemoryStream;
  img: TClipPixelImage;
  rd: TFPReaderPNG;
begin
  Result := False;
  AImg := Default(TClipImage);
  AWhy := '';
  if not PngFraming(AData, w, h, AWhy) then
    Exit;
  ms := TMemoryStream.Create;
  img := TClipPixelImage.Create(0, 0);
  rd := TFPReaderPNG.Create;
  try
    try
      ms.WriteBuffer(AData[1], Length(AData));
      ms.Position := 0;
      img.UsePalette := False;   // des couleurs, pas des index qu'on jetterait
      img.LoadFromStream(ms, rd);
      if (img.FImg.Width <> Integer(w)) or (img.FImg.Height <> Integer(h)) then
      begin
        AWhy := 'inconsistent PNG';
        Exit;
      end;
      AImg := img.FImg;
      Result := True;
    except
      AWhy := 'unreadable PNG';
    end;
  finally
    rd.Free;
    img.Free;
    ms.Free;
  end;
end;

function PngEncode(const AImg: TClipImage): RawByteString;
var
  ms: TMemoryStream;
  img: TClipPixelImage;
  wr: TFPWriterPNG;
begin
  Result := '';
  if (AImg.Width <= 0) or (AImg.Height <= 0) or
     (Length(AImg.Pixels) < AImg.Width * AImg.Height) then
    Exit;
  ms := TMemoryStream.Create;
  img := TClipPixelImage.Create(0, 0);
  wr := TFPWriterPNG.Create;
  try
    img.SetSize(AImg.Width, AImg.Height);
    img.FImg.Pixels := Copy(AImg.Pixels, 0, AImg.Width * AImg.Height);
    wr.UseAlpha := True;
    wr.Indexed := False;
    wr.GrayScale := False;
    wr.WordSized := False;
    // le reseau coute plus que quelques pourcents de taille
    wr.CompressionLevel := clfastest;
    img.SaveToStream(ms, wr);
    SetLength(Result, ms.Size);
    if ms.Size > 0 then
      Move(ms.Memory^, Result[1], ms.Size);
  finally
    wr.Free;
    img.Free;
    ms.Free;
  end;
end;

end.
