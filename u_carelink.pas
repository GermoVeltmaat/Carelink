unit u_carelink;
{$mode ObjFPC}{$H+}
(*******************************************************************************
CopyFree 2023.

This work is provided "as is", without any express or implied warranties,
including but not limited to the implied warranties of merchantability and
fitness for a particular purpose.  In no event will the authors or contributors
be held liable for any direct, indirect, incidental, special, exemplary, or
consequential damages however caused and on any theory of liability, whether in
contract, strict liability, or tort (including negligence or otherwise),
arising in any way out of the use of this work, even if advised of the
possibility of such damage.

Permission is granted to anyone to use this work for any purpose, including
commercial applications, and to alter and distribute it freely in any form,
provided that the following conditions are met:

1. The origin of this work must not be misrepresented; you must not claim that
   you authored the original work. If you use this work in a product, an
   acknowledgment in the product documentation would be appreciated but is not
   required.

2. Altered versions in any form may not be misrepresented as being the original
   work.

3. The text of this notice must be included, unaltered, with any distribution.


              Nieuwleusen, juli 2023. CarelinkSoftware@germo.eu
*******************************************************************************)
interface
uses
  Classes,
  SysUtils,
  fpjson;

// gegevens voor account & opvragen geschiedenis
Var
  Carelink_Username : String = '';
  CareLink_Password : String = '';
  Carelink_Country  : String = 'nl';
  Carelink_Language : String = 'nl';
  Carelink_Server   : String = 'carelink.minimed.eu';

// klaarzetten gegevens om in te loggen
  Procedure ZetCredentials( Username : String = '';
                            Password : String = '';
                            Country  : String = '';
                            Language : String = '');
// opvragen laatste 24 uur
  Function GetLastData : TJsonData;


// werk variabelen en deel functies (om te debuggen)
Var
  FetchName  : String = ''; // gebruikersnaam om op te vragen
  FetchRole  : String = ''; // role = 'patient';
  FetchPoint : String = ''; // endpoint voor data opvragen

// Bearer Token en geldigheid
Var
  authentityToken  : string = '';
  authentityExpire : String = '';
  authentityValid  : TdateTime = 0.0;

  Function Authentity : String;   // Bearer token, log (opnieuw) in indien nodig
  Function GetMyUser : TJSONStringType;                // gegevens van gebruiker
  Function GetMyProfile : TJSONStringType;               // gegevens van profiel
  Function GetCountrySettings : TJSONStringType;            // gegevens van land
  Function GetMonitorData : TJSONStringType;                     // soort opslag
//  Function GetLast24Hours : String;                     // obsolete functie ??
  Function GetData( ProfileUsername,ProfileRole,
                    EndpointURL : String) : TJSONStringType; // laatste gegevens

implementation

Uses
  HttpSend,
  ssl_openssl,
  fphttpclient,
  SynaUtil,
  dateutils;

// aanpassen name-value-seperator voor header velden
Type TMyHttp = class(THTTPSend) constructor Create; end;
Constructor TMyHTTP.Create; Begin Inherited Create; Headers.NameValueSeparator := ':'; end;
// ---------------------------------------------------------

// probeer Json te maken van string, loop niet vast als dat niet lukt
Function String2JSON(Source : String) : TJSonData;
Begin
  Result := nil;
  Try
    If (Source.StartsWith('{') And Source.EndsWith('}')) Then
      Result := GetJSON(Source);
  Except
    Result := nil;
    end;
  end;

// zoek deel uit string (info uit html page)
Function partof(Source, Start, eind : String) : String;
Var
  Indx : integer;
Begin
  Result := '';
  Indx := pos(Start,Source);
  If Indx <= 0 Then exit;
  Indx := Indx + length(Start);
  Result := copy(Source,indx,length(source));
  Indx := pos(eind,result);
  If Indx <= 0 Then exit;
  Result := copy(Result,1,indx-1);
  End;

// splitsen header info naar velden
Function Url2PayLoad(Url : String; Var params : TStrings) : String;
Var
  Indx : Integer;
  pl : String;
Begin
  Indx := Pos('?',URL);
  If Indx < 0 Then Begin
    Result := Url;
    Exit;
    End;
  Result := Copy(URL,1,Indx-1);
  Params := TStringList.Create;
  pl := copy(url,Indx+1);
  Params.Delimiter := '&';
  Params.DelimitedText := Pl;
  Params.NameValueSeparator := '=';
  end;

// maak payload string van velden
Function Fields2Payload(F : array of string) : String;
Var
  Indx,l,o : Integer;
Begin
  Result := '';
  l := Length(f) Div 2;
  For Indx := 1 to l Do Begin
    o := (Indx - 1) * 2;
    If Indx > 1 Then Result := Result + '&';
    Result := Result + EncodeURLElement(f[o]) + '=' + EncodeURLElement(f[o+1]);
    end;
  end;

// Carelink constanten
Const
  CARELINK_CONNECT_SERVER_EU = 'carelink.minimed.eu';
  CARELINK_CONNECT_SERVER_US = 'carelink.minimed.com';
  CARELINK_AUTH_TOKEN_COOKIE_NAME = 'auth_tmp_token';
  CARELINK_TOKEN_VALIDTO_COOKIE_NAME = 'c_token_valid_to';

// Opvragen authorisatie bij medtronic server
Function GetAuthToken( Var Token : String;
                       Var Validity : String) : Boolean;
Var
  HttpSessie : TMyHTTP;
  LoginSessionURL,
  LoginURL,
  CredentialsURL,
  consenturl, sesid, sesdata,
  AuthURL                      : String;
// werk vars
  Params : TStrings;
  Form,resp : String;
Begin
  Result := False;
  HttpSessie := TMyHTTP.Create;
  Try
// vraag voor een login sessie voor goede land en taal
    LoginSessionURL := 'https://' + CARELINK_CONNECT_SERVER_EU + '/patient/sso/login' +
                           '?' + Fields2Payload([ 'country',Carelink_Country,
                                                  'lang',Carelink_Language]);
    if HttpSessie.HTTPMethod('GET',LoginSessionURL) then begin
// vraag FORM gegevens op om te kunnen inloggen
      LoginURL := Trim(HttpSessie.Headers.Values['Location']);
      HttpSessie.Clear;
      If HttpSessie.HTTPMethod('GET',LoginURL) Then Begin
// haal gegevens uit resultaat
        Resp := Trim(HttpSessie.Headers.Values['Location']);
// splits url en gegevens
        HttpSessie.Clear;
        CredentialsURL := Url2PayLoad(Resp,Params{%H-});
// info maken
        CredentialsURL := CredentialsURL + '?' + Fields2Payload([ 'country',params.Values['countrycode'],
                                                                  'locale', params.Values['locale'] ]);
// gegevens in FORM zetten
        Form := Fields2Payload([ 'sessionID', params.Values['sessionID'],
                                 'sessionData', params.Values['sessionData'],
                                 'locale', params.Values['locale'],
                                 'action', 'login',
                                 'username', Carelink_Username,
                                 'password', CareLink_Password,
                                 'actionButton', 'Log in']);
// Deze hebben we niet meer nodig
        FreeAndNil(Params);
// Nu alles invoegen
        HttpSessie.Document.Clear;
        WriteStrToStream(HttpSessie.Document, Form);
        HttpSessie.MimeType := 'application/x-www-form-urlencoded';
// verstuur log-in FORM
        If HttpSessie.HTTPMethod('POST', CredentialsURL) Then Begin
// pak gegevens voor consent
          Resp := ReadStrFromStream(HttpSessie.Document,HttpSessie.Document.Size);
          consenturl := partof(resp, 'form action="',              '"');
          sesid      := partof(resp, 'name="sessionID" value="',   '"');
          sesdata    := partof(resp, 'name="sessionData" value="', '"');
// maak consent form
          form := Fields2Payload([ 'action', 'consent',
                                   'sessionID', sesid,
                                   'sessionData', sesdata,
                                   'response_type', 'code',
                                   'response_mode', 'query']);
// Nu alles invoegen
          HttpSessie.Clear;
          WriteStrToStream(HttpSessie.Document, Form);
          HttpSessie.MimeType := 'application/x-www-form-urlencoded';
// verstuur consent FORM
          If HttpSessie.HTTPMethod('POST', consenturl) Then Begin
// haal gegevens uit resultaat
            AuthURL := Trim(HttpSessie.Headers.Values['Location']);
// Auth gegevens opvragen
            HttpSessie.Clear;
            If HttpSessie.HTTPMethod('GET', AuthURL) Then Begin
// bewaar authorisatie in proc vars
              Token := Trim(HttpSessie.Cookies.Values['auth_tmp_token']);
              Validity :=  Trim(HttpSessie.Cookies.Values['c_token_valid_to']);
              Result := True
              End; // get token
            End; // consent form
          End; // login form
        End; // login
      End; // loginsession
  finally
// opruimen websessie
    FreeAndNil(HttpSessie);
    end;
  End;

// Bearer token om gegevens op te vragen. Logt (opnieuw) in om op te vragen indien nodig
function Authentity: String;
Var
  authcookie : String = '';
  authvalid  : string = '';
Begin
  If (authentityToken = '') Or (Now() >= authentityValid) Then Begin
    authentityToken := '';
    authentityValid := now();
    If GetAuthToken(AuthCookie,AuthValid) Then Begin
      authentityToken := authcookie;
      authentityExpire := authvalid;
      authentityValid := UniversalTimeToLocal(ScanDateTime('ddd mmm dd hh:nn:ss "UTC" yyyy', AuthValid));
      End; // token gekregen
    end; // token niet (meer) geldig
  If (authentityToken <> '') And (authentityValid > Now()) Then
    Result := 'Bearer ' + authentityToken
  Else
    Result := '';
  end;

// opvragen user gegevens (naam, adres, etc)
function GetMyUser: TJSONStringType;
Var
  FWebSession : TMyHTTP;
  Auth, genurl : String;
Begin
  Result := '';
  FWebSession := TMyHTTP.Create;
  Try
    genurl := 'https://' + CARELINK_CONNECT_SERVER_EU + '/patient/users/me';
    Auth := Authentity;
    If Auth <> '' Then Begin
      FWebSession.Headers.Values['Authorization'] := Auth;
      FWebSession.Headers.Values[CARELINK_AUTH_TOKEN_COOKIE_NAME] := authentityToken;
      FWebSession.Headers.Values[CARELINK_TOKEN_VALIDTO_COOKIE_NAME] := authentityExpire;
      FWebSession.Headers.Values['Accept'] := 'application/json, text/plain, */*';
      FWebSession.Headers.Values['Content-Type'] := 'application/json; charset=utf-8';
      FWebSession.MimeType := 'application/json; charset=utf-8';
      If FWebSession.HTTPMethod('GET', genurl) Then
        Result := ReadStrFromStream(FWebSession.Document,FWebSession.Document.Size);
      End;
  Finally
    FreeAndNil(FWebSession);
    End;
  End;

// opvragen profiel gegevens (voor opvraag-FetchName)
function GetMyProfile: TJSONStringType;
Var
  FWebSession : TMyHTTP;
  Auth, genurl : String;
Begin
  Result := '';
  FWebSession := TMyHTTP.Create;
  Try
    genurl := 'https://' + CARELINK_CONNECT_SERVER_EU + '/patient/users/me/profile';
    Auth := Authentity;
    If Auth <> '' Then Begin
      FWebSession.Headers.Values['Authorization'] := Auth;
      FWebSession.Headers.Values['auth_tmp_token'] := authentityToken;
      FWebSession.Headers.Values['c_token_valid_to'] := authentityExpire;
      FWebSession.Headers.Values['Accept'] := 'application/json, text/plain, */*';
      FWebSession.Headers.Values['Content-Type'] := 'application/json; charset=utf-8';
      FWebSession.MimeType := 'application/json; charset=utf-8';
      If FWebSession.HTTPMethod('GET', genurl) Then
        Result := ReadStrFromStream(FWebSession.Document,FWebSession.Document.Size);
      End;
  Finally
    FreeAndNil(FWebSession);
    End;
  End;

// opvragen land gegevens (voor endpoint adres (FetchPoint))
function GetCountrySettings: TJSONStringType;
Var
  FWebSession : TMyHTTP;
  Auth, genurl : String;
Begin
  Result := '';
  FWebSession := TMyHTTP.Create;
  Try
    genurl := 'https://' + CARELINK_CONNECT_SERVER_EU + '/patient/countries/settings/' +
                        '?' + Fields2Payload([ 'countryCode', Carelink_Country,
                                               'locale', Carelink_Language     ]);
    Auth := Authentity;
    If Auth <> '' Then Begin
      FWebSession.Headers.Values['Authorization'] := Auth;
      FWebSession.Headers.Values['auth_tmp_token'] := authentityToken;
      FWebSession.Headers.Values['c_token_valid_to'] := authentityExpire;
      FWebSession.Headers.Values['Accept'] := 'application/json, text/plain, */*';
      FWebSession.Headers.Values['Content-Type'] := 'application/json; charset=utf-8';
      FWebSession.MimeType := 'application/json; charset=utf-8';
      If FWebSession.HTTPMethod('GET', genurl) Then
        Result := ReadStrFromStream(FWebSession.Document,FWebSession.Document.Size);
      End;
  Finally
    FreeAndNil(FWebSession);
    End;
  End;

// opvragen welke soort gegevens
// gebruik ik niet, maar is om te kiezen tussen "getlast24hours" of "getdata()"
function GetMonitorData: TJSONStringType;
Var
  FWebSession : TMyHTTP;
  Auth, genurl : String;
Begin
  Result := '';
  FWebSession := TMyHTTP.Create;
  Try
    genurl := 'https://' + CARELINK_CONNECT_SERVER_EU + '/patient/monitor/data';
    Auth := Authentity;
    If Auth <> '' Then Begin
      FWebSession.Headers.Values['Authorization'] := Auth;
      FWebSession.Headers.Values['auth_tmp_token'] := authentityToken;
      FWebSession.Headers.Values['c_token_valid_to'] := authentityExpire;
      FWebSession.Headers.Values['Accept'] := 'application/json, text/plain, */*';
      FWebSession.Headers.Values['Content-Type'] := 'application/json; charset=utf-8';
      FWebSession.MimeType := 'application/json; charset=utf-8';
      If FWebSession.HTTPMethod('GET', genurl) Then
        Result := ReadStrFromStream(FWebSession.Document,FWebSession.Document.Size);
      End;
  Finally
    FreeAndNil(FWebSession);
    End;
  End;

// Obsolete function ??
// not used in my setup, so not debugged
//Function GetLast24Hours : String;
//Var
//  FWebSession : TMyHTTP;
//  Auth, genurl, tijd : String;
//
//Begin
//  Result := '';
//  FWebSession := TMyHTTP.Create;
//  Try
////    tijd := IntToStr(DateTimeToUnix(Now()));
//    tijd := '1688565935'; //097';
// tijd var not checked !!
//    genurl := 'https://' + CARELINK_CONNECT_SERVER_EU + '/patient/connect/data/' +
//                        '?' + Fields2Payload([ 'cpSerialNumber', 'NONE',
//                                               'msgType',        'last24hours',
//                                               'requestTime',    Tijd ]);
//    Auth := Authentity;
//    If Auth <> '' Then Begin
//      FWebSession.Headers.Values['Authorization'] := Auth;
//      FWebSession.Headers.Values['auth_tmp_token'] := authentityToken;
//      FWebSession.Headers.Values['c_token_valid_to'] := authentityExpire;
//      FWebSession.Headers.Values['Accept'] := 'application/json, text/plain, */*';
//      FWebSession.Headers.Values['Content-Type'] := 'application/json; charset=utf-8';
//      FWebSession.MimeType := 'application/json; charset=utf-8';
//      If FWebSession.HTTPMethod('GET', genurl) Then
//        Result := ReadStrFromStream(FWebSession.Document,FWebSession.Document.Size);
//      End;
//  Finally
//    FreeAndNil(FWebSession);
//    End;
//  End;

// opvragen data voor gebruiker
function GetData( ProfileUsername,
                  ProfileRole,
                  EndpointURL: String): TJSONStringType;
Var
  FWebSession : TMyHTTP;
  Auth, Form : String;
Begin
  Result := '';
  FWebSession := TMyHTTP.Create;
  Try
    Auth := Authentity;
    If Auth <> '' Then Begin
      FWebSession.Headers.Values['Authorization'] := Auth;
      FWebSession.Headers.Values['auth_tmp_token'] := authentityToken;
      FWebSession.Headers.Values['c_token_valid_to'] := authentityExpire;
      FWebSession.Headers.Values['Accept'] := 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9';
      FWebSession.Headers.Values['Content-Type'] := 'application/x-www-form-urlencoded';
// gegevens in FORM zetten (als JSON)
      Form := TJSONObject.Create([ 'username', ProfileUsername,
                                   'role',     ProfileRole ]).AsJSON;
// Nu alles invoegen
      WriteStrToStream(FwebSession.Document, Form);
      FWebSession.MimeType := 'application/x-www-form-urlencoded';
      If FWebSession.HTTPMethod('POST', EndpointURL) Then
        Result := ReadStrFromStream(FWebSession.Document,FWebSession.Document.Size);
      End;
  Finally
    FreeAndNil(FWebSession);
    End;
  End;

// zet alles klaar om contact te maken
procedure ZetCredentials( Username: String;
                          Password: String;
                          Country: String;
                          Language: String);
begin
  If Username <> '' Then Carelink_Username := UserName;
  If Password <> '' Then CareLink_Password := Password;
  If Country  <> '' Then Begin
    Carelink_Country := Country;
    If Carelink_Country = 'us' Then Carelink_Server := CARELINK_CONNECT_SERVER_US
                               Else Carelink_Server := CARELINK_CONNECT_SERVER_EU;
    End;
  If Language <> '' Then Carelink_Language := Language;
  end;

// opvragen laatste 24 uur
function GetLastData: TJsonData;
Var
  Json : TJsonData;
Begin
  Result := nil;
  If Authentity = '' Then Exit; // geen login => exit
// zorg dat we een FetchName hebben
  If FetchName = '' Then Begin
    Json := String2JSON(GetMyProfile);
    If Assigned(Json) Then Begin
      FetchName := json.findPath('username').AsString;
      end;
    End;
  If FetchName = '' Then Exit;
// maak een role (zou n.a.v. monitordata moeten)
  If FetchRole = '' Then FetchRole := 'patient';
// zorg dat we een opvraagurl hebben
  If FetchPoint = '' Then Begin
    Json := String2JSON(GetCountrySettings);
    If Assigned(Json) Then Begin
      FetchPoint := json.findPath('blePereodicDataEndpoint').AsString;
      end;
    End;
  If FetchPoint = '' Then Exit;;
// nu opvragen
  Result := String2JSON(GetData(FetchName,FetchRole,FetchPoint));
  end;

end.

