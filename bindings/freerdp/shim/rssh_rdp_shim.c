/*
 * rssh_rdp_shim -- oracle de disposition memoire pour FreeRDP 3: compile
 * contre les vrais en-tetes de la machine, le compilateur C resout les champs
 * que le Pascal atteint sinon par decalages devines (faux en ECRITURE, ils
 * ecrasent la memoire d'autrui). Ne lie PAS FreeRDP -- en-tetes seuls, le
 * chargement par chemin absolu du programme reste intact. Zero
 * allocation, zero copie; pointeurs, tailles et sorties verifies.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <freerdp/version.h>
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/channels.h>

#if defined(_WIN32)
#define RSSH_API __declspec(dllexport)
#else
#define RSSH_API __attribute__((visibility("default")))
#endif

/*
 * Contrat shim<->binding: a incrementer des qu'une signature change. Le
 * Pascal refuse toute version differente et retombe sur ses decalages en dur.
 *   2: poseurs rssh_instance_set_* (rappels de l'instance et ContextSize).
 *   3: poseurs rssh_ep_set_client_new / _client_free -- plus aucune ecriture
 *      Pascal par decalage devine quand le shim est la.
 */
#define RSSH_SHIM_ABI 3u

RSSH_API uint32_t rssh_abi_version(void)
{
	return RSSH_SHIM_ABI;
}

/* Tailles: sous-estimer sizeof(rdpContext) ferait ecrire FreeRDP par-dessus
 * ce que le transport range juste apres. On ne devine plus. */

RSSH_API size_t rssh_sizeof_context(void)
{
	return sizeof(rdpContext);
}

RSSH_API size_t rssh_sizeof_entry_points(void)
{
	return sizeof(RDP_CLIENT_ENTRY_POINTS);
}

/* Version FreeRDP de compilation (major*10000 + minor*100 + revision): le
 * binding ecarte un shim batti contre une autre version que la chargee. */
RSSH_API uint32_t rssh_built_version(void)
{
	return (uint32_t)(FREERDP_VERSION_MAJOR * 10000 +
	                  FREERDP_VERSION_MINOR * 100 + FREERDP_VERSION_REVISION);
}

RSSH_API uint32_t rssh_client_interface_version(void)
{
	return (uint32_t)RDP_CLIENT_INTERFACE_VERSION;
}

/* Entry points dans le tampon de l'appelant: taille verifiee, tampon remis a
 * zero (un champ residuel serait pris pour un rappel valide). */
RSSH_API int rssh_ep_init(void* buf, size_t buflen, size_t context_size)
{
	RDP_CLIENT_ENTRY_POINTS* ep;

	if (buf == NULL)
		return 0;
	if (buflen < sizeof(RDP_CLIENT_ENTRY_POINTS))
		return 0;
	if (context_size < sizeof(rdpContext))
		return 0;
	/* ContextSize est 32 bits: tronquer ferait allouer trop petit, on refuse */
	if (context_size > 0xFFFFFFFFu)
		return 0;

	ep = (RDP_CLIENT_ENTRY_POINTS*)buf;
	memset(ep, 0, sizeof(RDP_CLIENT_ENTRY_POINTS));
	ep->Size = (UINT32)sizeof(RDP_CLIENT_ENTRY_POINTS);
	ep->Version = RDP_CLIENT_INTERFACE_VERSION;
	ep->ContextSize = (DWORD)context_size;
	return 1;
}

/* Poses ici, ou le compilateur connait la struct: un offset faux ne deborde
 * pas du tampon mais remplirait un AUTRE champ. */
RSSH_API int rssh_ep_set_client_new(void* buf, size_t buflen, void* cb)
{
	if (buf == NULL || buflen < sizeof(RDP_CLIENT_ENTRY_POINTS))
		return 0;
	/* memcpy: pas de transtypage objet -> fonction (UB) */
	memcpy(&((RDP_CLIENT_ENTRY_POINTS*)buf)->ClientNew, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_ep_set_client_free(void* buf, size_t buflen, void* cb)
{
	if (buf == NULL || buflen < sizeof(RDP_CLIENT_ENTRY_POINTS))
		return 0;
	memcpy(&((RDP_CLIENT_ENTRY_POINTS*)buf)->ClientFree, &cb, sizeof(void*));
	return 1;
}

/* rdpContext */

RSSH_API void* rssh_ctx_instance(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->instance : NULL;
}

RSSH_API void* rssh_ctx_gdi(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->gdi : NULL;
}

RSSH_API void* rssh_ctx_input(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->input : NULL;
}

RSSH_API void* rssh_ctx_settings(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->settings : NULL;
}

RSSH_API void* rssh_ctx_update(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->update : NULL;
}

RSSH_API void* rssh_ctx_channels(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->channels : NULL;
}

RSSH_API void* rssh_ctx_pubsub(const void* ctx)
{
	return ctx ? (void*)((const rdpContext*)ctx)->pubSub : NULL;
}

RSSH_API uint32_t rssh_ctx_last_error(const void* ctx)
{
	return ctx ? (uint32_t)((const rdpContext*)ctx)->LastError : 0u;
}

RSSH_API void* rssh_instance_context(const void* instance)
{
	return instance ? (void*)((const freerdp*)instance)->context : NULL;
}

/* rdpGdi */

RSSH_API int32_t rssh_gdi_width(const void* gdi)
{
	return gdi ? (int32_t)((const rdpGdi*)gdi)->width : 0;
}

RSSH_API int32_t rssh_gdi_height(const void* gdi)
{
	return gdi ? (int32_t)((const rdpGdi*)gdi)->height : 0;
}

RSSH_API uint32_t rssh_gdi_stride(const void* gdi)
{
	return gdi ? (uint32_t)((const rdpGdi*)gdi)->stride : 0u;
}

RSSH_API uint32_t rssh_gdi_dst_format(const void* gdi)
{
	return gdi ? (uint32_t)((const rdpGdi*)gdi)->dstFormat : 0u;
}

RSSH_API uint8_t* rssh_gdi_primary_buffer(const void* gdi)
{
	return gdi ? (uint8_t*)((const rdpGdi*)gdi)->primary_buffer : NULL;
}

/* gdi->primary->hdc->hwnd->invalid: la chaine qui, sur un decalage faux, se
 * traverse sans planter et rend n'importe quoi. Chaque maillon est verifie. */
static HGDI_RGN rssh_invalid_rgn(void* gdi)
{
	rdpGdi* g = (rdpGdi*)gdi;

	if (g == NULL || g->primary == NULL)
		return NULL;
	if (g->primary->hdc == NULL || g->primary->hdc->hwnd == NULL)
		return NULL;
	return g->primary->hdc->hwnd->invalid;
}

/* decide une fois par session: region invalidee, ou recopie du framebuffer */
RSSH_API int rssh_gdi_invalid_chain_ok(void* gdi)
{
	return rssh_invalid_rgn(gdi) != NULL ? 1 : 0;
}

/* sorties ecrites seulement en cas de succes: jamais de valeurs partielles */
RSSH_API int rssh_gdi_take_invalid(void* gdi, int32_t* x, int32_t* y,
                                   int32_t* w, int32_t* h)
{
	HGDI_RGN rgn;

	if (x == NULL || y == NULL || w == NULL || h == NULL)
		return 0;
	rgn = rssh_invalid_rgn(gdi);
	if (rgn == NULL)
		return 0;
	if (rgn->null)
		return 0;
	if (rgn->w <= 0 || rgn->h <= 0)
		return 0;
	*x = (int32_t)rgn->x;
	*y = (int32_t)rgn->y;
	*w = (int32_t)rgn->w;
	*h = (int32_t)rgn->h;
	return 1;
}

/* role de gdi_begin_paint, qu'on remplace: sinon la region ne fait que grossir */
RSSH_API int rssh_gdi_reset_invalid(void* gdi)
{
	rdpGdi* g = (rdpGdi*)gdi;
	HGDI_RGN rgn = rssh_invalid_rgn(gdi);

	if (rgn == NULL)
		return 0;
	rgn->null = TRUE;
	g->primary->hdc->hwnd->ninvalid = 0;
	return 1;
}

/* rdpUpdate: trois champs ECRITS, le chemin le plus sensible */

RSSH_API void* rssh_update_context(const void* upd)
{
	return upd ? (void*)((const rdpUpdate*)upd)->context : NULL;
}

RSSH_API int rssh_update_set_begin_paint(void* upd, void* cb)
{
	if (upd == NULL)
		return 0;
	memcpy(&((rdpUpdate*)upd)->BeginPaint, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_update_set_end_paint(void* upd, void* cb)
{
	if (upd == NULL)
		return 0;
	memcpy(&((rdpUpdate*)upd)->EndPaint, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_update_set_desktop_resize(void* upd, void* cb)
{
	if (upd == NULL)
		return 0;
	memcpy(&((rdpUpdate*)upd)->DesktopResize, &cb, sizeof(void*));
	return 1;
}

/* freerdp (instance): rappels ECRITS avant connexion, depuis ClientNew */

RSSH_API size_t rssh_instance_context_size(const void* instance)
{
	return instance ? ((const freerdp*)instance)->ContextSize : 0;
}

RSSH_API int rssh_instance_set_context_size(void* instance, size_t size)
{
	if (instance == NULL)
		return 0;
	if (size < sizeof(rdpContext))
		return 0;
	((freerdp*)instance)->ContextSize = size;
	return 1;
}

RSSH_API int rssh_instance_set_pre_connect(void* instance, void* cb)
{
	if (instance == NULL)
		return 0;
	memcpy(&((freerdp*)instance)->PreConnect, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_instance_set_post_connect(void* instance, void* cb)
{
	if (instance == NULL)
		return 0;
	memcpy(&((freerdp*)instance)->PostConnect, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_instance_set_post_disconnect(void* instance, void* cb)
{
	if (instance == NULL)
		return 0;
	memcpy(&((freerdp*)instance)->PostDisconnect, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_instance_set_verify_certificate_ex(void* instance, void* cb)
{
	if (instance == NULL)
		return 0;
	memcpy(&((freerdp*)instance)->VerifyCertificateEx, &cb, sizeof(void*));
	return 1;
}

RSSH_API int rssh_instance_set_verify_changed_certificate_ex(void* instance,
                                                             void* cb)
{
	if (instance == NULL)
		return 0;
	memcpy(&((freerdp*)instance)->VerifyChangedCertificateEx, &cb,
	       sizeof(void*));
	return 1;
}

/* canaux: evenement de connexion, resolution dynamique */

/* chaine EMPRUNTEE: ne pas liberer, ne pas garder au-dela de l'evenement */
RSSH_API const char* rssh_chanevt_name(const void* evt)
{
	return evt ? ((const ChannelConnectedEventArgs*)evt)->name : NULL;
}

RSSH_API void* rssh_chanevt_interface(const void* evt)
{
	return evt ? (void*)((const ChannelConnectedEventArgs*)evt)->pInterface
	           : NULL;
}

RSSH_API void* rssh_disp_send_layout(const void* disp)
{
	void* p = NULL;

	if (disp == NULL)
		return NULL;
	memcpy(&p, &((const DispClientContext*)disp)->SendMonitorLayout,
	       sizeof(void*));
	return p;
}

/* cliprdr: emplacements NOMMES plutot que decalages numeriques */

enum rssh_cliprdr_slot {
	RSSH_CLIP_SERVER_CAPABILITIES = 0,
	RSSH_CLIP_CLIENT_CAPABILITIES = 1,
	RSSH_CLIP_MONITOR_READY = 2,
	RSSH_CLIP_CLIENT_FORMAT_LIST = 3,
	RSSH_CLIP_SERVER_FORMAT_LIST = 4,
	RSSH_CLIP_CLIENT_FORMAT_LIST_RESPONSE = 5,
	RSSH_CLIP_SERVER_FORMAT_LIST_RESPONSE = 6,
	RSSH_CLIP_CLIENT_FORMAT_DATA_REQUEST = 7,
	RSSH_CLIP_SERVER_FORMAT_DATA_REQUEST = 8,
	RSSH_CLIP_CLIENT_FORMAT_DATA_RESPONSE = 9,
	RSSH_CLIP_SERVER_FORMAT_DATA_RESPONSE = 10
};

/* NULL si slot inconnu: jamais d'adresse approchante */
static void** rssh_cliprdr_slot_addr(CliprdrClientContext* c, uint32_t slot)
{
	if (c == NULL)
		return NULL;
	switch (slot) {
	case RSSH_CLIP_SERVER_CAPABILITIES:
		return (void**)&c->ServerCapabilities;
	case RSSH_CLIP_CLIENT_CAPABILITIES:
		return (void**)&c->ClientCapabilities;
	case RSSH_CLIP_MONITOR_READY:
		return (void**)&c->MonitorReady;
	case RSSH_CLIP_CLIENT_FORMAT_LIST:
		return (void**)&c->ClientFormatList;
	case RSSH_CLIP_SERVER_FORMAT_LIST:
		return (void**)&c->ServerFormatList;
	case RSSH_CLIP_CLIENT_FORMAT_LIST_RESPONSE:
		return (void**)&c->ClientFormatListResponse;
	case RSSH_CLIP_SERVER_FORMAT_LIST_RESPONSE:
		return (void**)&c->ServerFormatListResponse;
	case RSSH_CLIP_CLIENT_FORMAT_DATA_REQUEST:
		return (void**)&c->ClientFormatDataRequest;
	case RSSH_CLIP_SERVER_FORMAT_DATA_REQUEST:
		return (void**)&c->ServerFormatDataRequest;
	case RSSH_CLIP_CLIENT_FORMAT_DATA_RESPONSE:
		return (void**)&c->ClientFormatDataResponse;
	case RSSH_CLIP_SERVER_FORMAT_DATA_RESPONSE:
		return (void**)&c->ServerFormatDataResponse;
	default:
		return NULL;
	}
}

RSSH_API int rssh_cliprdr_set_custom(void* c, void* data)
{
	if (c == NULL)
		return 0;
	((CliprdrClientContext*)c)->custom = data;
	return 1;
}

RSSH_API void* rssh_cliprdr_custom(const void* c)
{
	return c ? ((const CliprdrClientContext*)c)->custom : NULL;
}

RSSH_API int rssh_cliprdr_set_handler(void* c, uint32_t slot, void* cb)
{
	void** addr = rssh_cliprdr_slot_addr((CliprdrClientContext*)c, slot);

	if (addr == NULL)
		return 0;
	memcpy(addr, &cb, sizeof(void*));
	return 1;
}

RSSH_API void* rssh_cliprdr_call(void* c, uint32_t slot)
{
	void* p = NULL;
	void** addr = rssh_cliprdr_slot_addr((CliprdrClientContext*)c, slot);

	if (addr == NULL)
		return NULL;
	memcpy(&p, addr, sizeof(void*));
	return p;
}
