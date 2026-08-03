/* Offsets rfbClient pour bindings/libvnc/uLibVncApi.pas. La disposition depend
 * de la config de compilation (rfbconfig.h): un record Pascal retranscrit
 * corromprait la memoire des que la lib locale differe. Source correspondante
 * GPL-3.0 section 1, voir LICENSES/THIRD-PARTY-NOTICES.md.
 *
 *   cc -I$(brew --prefix libvncserver)/include scripts/gen-vnc-offsets.c \
 *      -o /tmp/gen-vnc-offsets && /tmp/gen-vnc-offsets
 */
#include <stdio.h>
#include <stddef.h>
#include <rfb/rfbclient.h>

#define OFF(f) printf("  VNC_OFF_%-24s = %zu;\n", #f, offsetof(rfbClient, f))

int main(void)
{
    printf("  // ---- offsets rfbClient (generes par scripts/gen-vnc-offsets.c) ----\n");
    /* les macros de version sont des chaines dans rfbconfig.h, pas des entiers */
    printf("  // libvncclient %s.%s.%s\n",
           LIBVNCSERVER_VERSION_MAJOR, LIBVNCSERVER_VERSION_MINOR,
           LIBVNCSERVER_VERSION_PATCHLEVEL);

    /* etat serveur / framebuffer */
    OFF(frameBuffer);
    OFF(width);
    OFF(height);
    OFF(format);
    OFF(si);
    OFF(desktopName);
    OFF(serverHost);
    OFF(serverPort);
    OFF(sock);
    /* listenSpecified vrai = rfbInitConnection saute la connexion et attaque le
     * handshake sur `sock`: notre crochet pour connecter nous-memes, annulable */
    OFF(listenSpecified);
    OFF(connectTimeout);
    OFF(readTimeout);
    OFF(programName);
    OFF(appData);
    OFF(clientData);
    OFF(updateRect);
    OFF(canHandleNewFBSize);

    /* callbacks */
    OFF(MallocFrameBuffer);
    OFF(GotFrameBufferUpdate);
    OFF(FinishedFrameBufferUpdate);
    OFF(GetPassword);
    OFF(GetCredential);
    OFF(GotXCutText);
    OFF(GotXCutTextUTF8);
    OFF(Bell);
    OFF(HandleKeyboardLedState);
    OFF(HandleTextChat);

    printf("  VNC_%-27s = %zu;\n", "SIZE_RFBCLIENT", sizeof(rfbClient));
    printf("\n  // ---- offsets rfbPixelFormat (dans rfbClient.format) ----\n");
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "BITSPERPIXEL",
           offsetof(rfbPixelFormat, bitsPerPixel));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "DEPTH", offsetof(rfbPixelFormat, depth));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "BIGENDIAN",
           offsetof(rfbPixelFormat, bigEndian));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "TRUECOLOUR",
           offsetof(rfbPixelFormat, trueColour));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "REDMAX", offsetof(rfbPixelFormat, redMax));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "GREENMAX", offsetof(rfbPixelFormat, greenMax));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "BLUEMAX", offsetof(rfbPixelFormat, blueMax));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "REDSHIFT", offsetof(rfbPixelFormat, redShift));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "GREENSHIFT",
           offsetof(rfbPixelFormat, greenShift));
    printf("  VNC_PF_OFF_%-21s = %zu;\n", "BLUESHIFT",
           offsetof(rfbPixelFormat, blueShift));
    printf("  VNC_%-27s = %zu;\n", "SIZE_PIXELFORMAT", sizeof(rfbPixelFormat));

    printf("\n  // ---- offsets AppData (dans rfbClient.appData) ----\n");
    printf("  VNC_AD_OFF_%-21s = %zu;\n", "ENCODINGSSTRING",
           offsetof(AppData, encodingsString));
    printf("  VNC_AD_OFF_%-21s = %zu;\n", "COMPRESSLEVEL",
           offsetof(AppData, compressLevel));
    printf("  VNC_AD_OFF_%-21s = %zu;\n", "QUALITYLEVEL",
           offsetof(AppData, qualityLevel));
    printf("  VNC_AD_OFF_%-21s = %zu;\n", "USEREMOTECURSOR",
           offsetof(AppData, useRemoteCursor));
    printf("  VNC_AD_OFF_%-21s = %zu;\n", "VIEWONLY", offsetof(AppData, viewOnly));
    printf("  VNC_AD_OFF_%-21s = %zu;\n", "SHAREDESKTOP",
           offsetof(AppData, shareDesktop));
    return 0;
}
