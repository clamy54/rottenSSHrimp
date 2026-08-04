/* Offsets rfbClient pour bindings/libvnc/uLibVncApi.pas. La disposition depend
 * de la config de compilation (rfbconfig.h): un record Pascal retranscrit
 * corromprait la memoire des que la lib locale differe. Source correspondante
 * GPL-3.0 section 1, voir LICENSES/THIRD-PARTY-NOTICES.md.
 *
 * A compiler contre les en-tetes de NOTRE construction, pas contre ceux du
 * systeme: c'est le rfbconfig.h genere par build-libvnc.sh qui fait foi.
 *
 *   ./scripts/build-libvnc.sh
 *   cc -Ithird_party/libvnc/out/include scripts/gen-vnc-offsets.c \
 *      -o /tmp/gen-vnc-offsets && /tmp/gen-vnc-offsets
 *
 * Les noms emis sont ceux des constantes Pascal: la sortie se colle telle
 * quelle dans la branche de plateforme correspondante de uLibVncApi.pas.
 * scripts/check-vnc-offsets.sh fait la comparaison automatiquement.
 */
#include <stdio.h>
#include <stddef.h>
#include <rfb/rfbclient.h>

/* n = nom de la constante Pascal, f = champ C. Les deux different la ou le
 * binding a raccourci (FINISHEDFBUPDATE / FinishedFrameBufferUpdate). */
#define OFF(n, f) printf("  VNC_OFF_%-21s = %zu;\n", n, offsetof(rfbClient, f))
#define SIZ(n, t) printf("  VNC_%-25s = %zu;\n", n, sizeof(t))
#define PF(n, f)  printf("  VNC_PF_OFF_%-12s = %zu;\n", n, offsetof(rfbPixelFormat, f))
#define AD(n, f)  printf("  VNC_AD_OFF_%-15s = %zu;\n", n, offsetof(AppData, f))

int main(void)
{
    /* Temoin de config: ces trois macros DEPLACENT des champs. Une table
     * generee sans JPEG recule clientData de 32 octets et sizeof de 40. */
    int with_zlib = 0, with_jpeg = 0, with_sasl = 0;
#ifdef LIBVNCSERVER_HAVE_LIBZ
    with_zlib = 1;
#endif
#ifdef LIBVNCSERVER_HAVE_LIBJPEG
    with_jpeg = 1;
#endif
#ifdef LIBVNCSERVER_HAVE_SASL
    with_sasl = 1;
#endif

    printf("  // ---- offsets rfbClient (generes par scripts/gen-vnc-offsets.c) ----\n");
    /* les macros de version sont des chaines dans rfbconfig.h, pas des entiers */
    printf("  // libvncclient %s.%s.%s\n",
           LIBVNCSERVER_VERSION_MAJOR, LIBVNCSERVER_VERSION_MINOR,
           LIBVNCSERVER_VERSION_PATCHLEVEL);
    printf("  // config: zlib=%d jpeg=%d sasl=%d\n",
           with_zlib, with_jpeg, with_sasl);

    /* etat serveur / framebuffer */
    OFF("FRAMEBUFFER", frameBuffer);
    OFF("WIDTH", width);
    OFF("HEIGHT", height);
    OFF("FORMAT", format);
    OFF("SI", si);
    OFF("DESKTOPNAME", desktopName);
    OFF("SERVERHOST", serverHost);
    OFF("SERVERPORT", serverPort);
    OFF("SOCK", sock);
    /* listenSpecified vrai = rfbInitConnection saute la connexion et attaque le
     * handshake sur `sock`: notre crochet pour connecter nous-memes, annulable */
    OFF("LISTENSPECIFIED", listenSpecified);
    OFF("CONNECTTIMEOUT", connectTimeout);
    OFF("READTIMEOUT", readTimeout);
    OFF("PROGRAMNAME", programName);
    OFF("APPDATA", appData);
    OFF("CLIENTDATA", clientData);
    OFF("UPDATERECT", updateRect);
    OFF("CANHANDLENEWFBSIZE", canHandleNewFBSize);

    /* callbacks */
    OFF("MALLOCFRAMEBUFFER", MallocFrameBuffer);
    OFF("GOTFRAMEBUFFERUPDATE", GotFrameBufferUpdate);
    OFF("FINISHEDFBUPDATE", FinishedFrameBufferUpdate);
    OFF("GETPASSWORD", GetPassword);
    OFF("GETCREDENTIAL", GetCredential);
    OFF("GOTXCUTTEXT", GotXCutText);
    OFF("GOTXCUTTEXTUTF8", GotXCutTextUTF8);
    OFF("BELL", Bell);
    OFF("HANDLEKEYBOARDLEDSTATE", HandleKeyboardLedState);
    OFF("HANDLETEXTCHAT", HandleTextChat);

    SIZ("SIZE_RFBCLIENT", rfbClient);

    printf("\n  // ---- offsets rfbPixelFormat (dans rfbClient.format) ----\n");
    PF("BITSPERPIXEL", bitsPerPixel);
    PF("DEPTH", depth);
    PF("BIGENDIAN", bigEndian);
    PF("TRUECOLOUR", trueColour);
    PF("REDMAX", redMax);
    PF("GREENMAX", greenMax);
    PF("BLUEMAX", blueMax);
    PF("REDSHIFT", redShift);
    PF("GREENSHIFT", greenShift);
    PF("BLUESHIFT", blueShift);
    /* aligne sur le bloc PF ci-dessus, pas sur celui de rfbClient */
    printf("  VNC_%-20s = %zu;\n", "SIZE_PIXELFORMAT", sizeof(rfbPixelFormat));

    printf("\n  // ---- offsets AppData (dans rfbClient.appData) ----\n");
    AD("SHAREDESKTOP", shareDesktop);
    AD("VIEWONLY", viewOnly);
    AD("ENCODINGSSTRING", encodingsString);
    AD("COMPRESSLEVEL", compressLevel);
    AD("QUALITYLEVEL", qualityLevel);
    AD("USEREMOTECURSOR", useRemoteCursor);
    return 0;
}
