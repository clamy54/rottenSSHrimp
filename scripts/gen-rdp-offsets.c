/*
 * Offsets des structs FreeRDP atteintes par decalage dans uFreeRdpApi.pas.
 * Rend des lignes « NOM = VALEUR; » que check-rdp-offsets.sh confronte aux
 * constantes Pascal -- la lib vient de la machine, pas de nous.
 *
 * cc gen-rdp-offsets.c -o gen-rdp-offsets $(pkg-config --cflags freerdp3 winpr3)
 */
#include <stddef.h>
#include <stdio.h>
#include <freerdp/freerdp.h>
#include <freerdp/client.h>          /* RDP_CLIENT_ENTRY_POINTS */
#include <freerdp/gdi/gdi.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/channels.h>

#define OFF(name, type, field) \
	printf("%-34s = %zu;\n", #name, offsetof(type, field))

int main(void)
{
	/* ---- rdpContext ---- */
	OFF(CTX_OFF_INSTANCE, rdpContext, instance);
	OFF(CTX_OFF_SERVERMODE, rdpContext, ServerMode);
	OFF(CTX_OFF_LASTERROR, rdpContext, LastError);
	OFF(CTX_OFF_PUBSUB, rdpContext, pubSub);
	OFF(CTX_OFF_GDI, rdpContext, gdi);
	OFF(CTX_OFF_CHANNELS, rdpContext, channels);
	OFF(CTX_OFF_INPUT, rdpContext, input);
	OFF(CTX_OFF_UPDATE, rdpContext, update);
	OFF(CTX_OFF_SETTINGS, rdpContext, settings);

	/* ---- rdpGdi ---- */
	OFF(GDI_OFF_CONTEXT, rdpGdi, context);
	OFF(GDI_OFF_WIDTH, rdpGdi, width);
	OFF(GDI_OFF_HEIGHT, rdpGdi, height);
	OFF(GDI_OFF_STRIDE, rdpGdi, stride);
	OFF(GDI_OFF_DSTFORMAT, rdpGdi, dstFormat);
	OFF(GDI_OFF_HDC, rdpGdi, hdc);
	OFF(GDI_OFF_PRIMARY, rdpGdi, primary);
	OFF(GDI_OFF_PRIMARY_BUFFER, rdpGdi, primary_buffer);

	/* ---- rdpUpdate: ces trois champs sont ECRITS ---- */
	OFF(UPD_OFF_CONTEXT, rdpUpdate, context);
	OFF(UPD_OFF_BEGINPAINT, rdpUpdate, BeginPaint);
	OFF(UPD_OFF_ENDPAINT, rdpUpdate, EndPaint);
	OFF(UPD_OFF_DESKTOPRESIZE, rdpUpdate, DesktopResize);

	/* ---- chaine de la region invalidee: gdi->primary->hdc->hwnd->invalid ---- */
	OFF(BITMAP_OFF_HDC, gdiBitmap, hdc);
	OFF(DC_OFF_HWND, GDI_DC, hwnd);
	OFF(WND_OFF_NINVALID, GDI_WND, ninvalid);
	OFF(WND_OFF_INVALID, GDI_WND, invalid);
	OFF(RGN_OFF_X, GDI_RGN, x);
	OFF(RGN_OFF_Y, GDI_RGN, y);
	OFF(RGN_OFF_W, GDI_RGN, w);
	OFF(RGN_OFF_H, GDI_RGN, h);
	OFF(RGN_OFF_NULL, GDI_RGN, null);

	/* ---- presse-papiers (CLIPRDR_OFF_CUSTOM est ECRIT) ---- */
	OFF(CLIPRDR_OFF_CUSTOM, CliprdrClientContext, custom);
	OFF(CLIPRDR_OFF_SERVER_CAPABILITIES, CliprdrClientContext, ServerCapabilities);
	OFF(CLIPRDR_OFF_CLIENT_CAPABILITIES, CliprdrClientContext, ClientCapabilities);
	OFF(CLIPRDR_OFF_MONITOR_READY, CliprdrClientContext, MonitorReady);
	OFF(CLIPRDR_OFF_CLIENT_FORMAT_LIST, CliprdrClientContext, ClientFormatList);
	OFF(CLIPRDR_OFF_SERVER_FORMAT_LIST, CliprdrClientContext, ServerFormatList);
	OFF(CLIPRDR_OFF_CLIENT_FORMAT_LIST_RESPONSE, CliprdrClientContext,
	    ClientFormatListResponse);
	OFF(CLIPRDR_OFF_SERVER_FORMAT_LIST_RESPONSE, CliprdrClientContext,
	    ServerFormatListResponse);
	OFF(CLIPRDR_OFF_CLIENT_FORMAT_DATA_REQUEST, CliprdrClientContext,
	    ClientFormatDataRequest);
	OFF(CLIPRDR_OFF_SERVER_FORMAT_DATA_REQUEST, CliprdrClientContext,
	    ServerFormatDataRequest);
	OFF(CLIPRDR_OFF_CLIENT_FORMAT_DATA_RESPONSE, CliprdrClientContext,
	    ClientFormatDataResponse);
	OFF(CLIPRDR_OFF_SERVER_FORMAT_DATA_RESPONSE, CliprdrClientContext,
	    ServerFormatDataResponse);

	/* ---- resolution dynamique et evenement de canal ---- */
	OFF(DISP_OFF_SENDLAYOUT, DispClientContext, SendMonitorLayout);
	OFF(CHANEVT_OFF_NAME, ChannelConnectedEventArgs, name);
	OFF(CHANEVT_OFF_INTERFACE, ChannelConnectedEventArgs, pInterface);

	/* ---- freerdp (instance): TOUS ces champs sont ECRITS ---- */
	OFF(RDP_OFF_CONTEXT, freerdp, context);
	OFF(RDP_OFF_CONTEXTSIZE, freerdp, ContextSize);
	OFF(RDP_OFF_CONTEXTNEW, freerdp, ContextNew);
	OFF(RDP_OFF_CONTEXTFREE, freerdp, ContextFree);
	OFF(RDP_OFF_PRECONNECT, freerdp, PreConnect);
	OFF(RDP_OFF_POSTCONNECT, freerdp, PostConnect);
	OFF(RDP_OFF_POSTDISCONNECT, freerdp, PostDisconnect);
	OFF(RDP_OFF_VERIFYCERTIFICATEEX, freerdp, VerifyCertificateEx);
	OFF(RDP_OFF_VERIFYCHANGEDCERTIFICATEEX, freerdp,
	    VerifyChangedCertificateEx);

	/* ---- RDP_CLIENT_ENTRY_POINTS: ECRITS aussi ---- */
	OFF(EP_OFF_SIZE, RDP_CLIENT_ENTRY_POINTS, Size);
	OFF(EP_OFF_VERSION, RDP_CLIENT_ENTRY_POINTS, Version);
	OFF(EP_OFF_CONTEXTSIZE, RDP_CLIENT_ENTRY_POINTS, ContextSize);
	OFF(EP_OFF_CLIENTNEW, RDP_CLIENT_ENTRY_POINTS, ClientNew);
	OFF(EP_OFF_CLIENTFREE, RDP_CLIENT_ENTRY_POINTS, ClientFree);
	OFF(EP_OFF_CLIENTSTART, RDP_CLIENT_ENTRY_POINTS, ClientStart);
	OFF(EP_OFF_CLIENTSTOP, RDP_CLIENT_ENTRY_POINTS, ClientStop);
	printf("%-34s = %zu;\n", "EP_SIZE", sizeof(RDP_CLIENT_ENTRY_POINTS));

	return 0;
}
