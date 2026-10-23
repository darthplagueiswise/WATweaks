#pragma once
#include <stddef.h>
#include <string.h>
#include "WAGRWAABCatalogPolicy.h"

typedef enum {
    WAGRConfigGroupMobileConfig = 0,
    WAGRConfigGroupComparison,
    WAGRConfigGroupDogfood,
    WAGRConfigGroupInternalTools,
    WAGRConfigGroupABProps,
    WAGRConfigGroupTransport,
    WAGRConfigGroupCount
} WAGRConfigControlGroup;

typedef struct {
    const char *selector;
    const char *title;
    const char *type;
    WAGRConfigControlGroup group;
    const char *image;
    const char *category;
} WAGRConfigControlDefinition;

/* Exact WAABProperties metadata from the supplied 26.40.10 IPA. These are
 * individual feature reads; no preset enables them or grants account identity. */
#define WAGR_CONTROL(s, t, k, g, i, c) {s, t, k, g, i, c}
static const WAGRConfigControlDefinition kWAGRConfigControls[] = {
    WAGR_CONTROL("waios_enable_sessionbased_mc", "MC da sessão autenticada", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_rollout_sessionbased_mc", "Rollout do MC autenticado", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_emergency_rollback_sessionbased_mc", "Rollback de emergência MC", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_lazyinit_sessionbased_mc", "Inicialização adiada do MC", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("enable_www_sessionbased_mc_sync", "Sincronização MC via WWW", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfigImpl"),
    WAGR_CONTROL("waios_mc_www_fetch_response_off_main_enabled", "Resposta WWW fora da thread principal", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfigImpl"),
    WAGR_CONTROL("ios_online_sessionless_guest_mc_context_cache_enabled", "Cache MC sessionless/guest", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_enable_sessionbased_mc_in_extension", "MC autenticado nas extensões", "B", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_sessionbased_mc_init_phase", "Fase de inicialização MC", "q", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_sessionbased_mc_init_phase_v2", "Fase de inicialização MC v2", "q", WAGRConfigGroupMobileConfig, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("ios_enable_mc_shadow_testing", "Shadow testing MC", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("ios_enable_mc_shadow_testing_with_init_groups", "Grupos de inicialização no shadow test", "q", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("ios_online_mc_shadow_logging_enabled", "Logs de shadow MC online", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("ios_prechat_guest_shadow_logging_enabled", "Logs shadow prechat guest", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("ios_prechat_sessionless_shadow_logging_enabled", "Logs shadow prechat sessionless", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_mc_abprops_compare_enabled", "Comparar ABProps e MC", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_mc_abprops_compare_interval_sec", "Intervalo da comparação (s)", "q", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_mc_batch_consistency_logging_interval_sec", "Intervalo dos logs de consistência (s)", "q", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_mc_chat_open_comp_log", "Comparação ao abrir conversa", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_mc_skip_param_value_logging", "Omitir valores dos parâmetros nos logs", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("waios_mc_specifier_direct_index_lookup", "Lookup direto de descritores MC", "B", WAGRConfigGroupComparison, "SharedModules", "WAMobileConfig"),
    WAGR_CONTROL("dogfooding_nudge_settings_entrypoint_enabled", "Entrada dogfood em Settings", "B", WAGRConfigGroupDogfood, "WhatsApp", "WASettingsMain"),
    WAGR_CONTROL("dogfooding_nudge_banner_home_screen_enabled", "Banner dogfood na tela inicial", "B", WAGRConfigGroupDogfood, "WhatsApp", "WABannersMain"),
    WAGR_CONTROL("hn_dogfooding", "HN dogfooding", "B", WAGRConfigGroupDogfood, "WhatsApp", "HNDogfooding"),
    WAGR_CONTROL("malibu_dogfooding", "Malibu dogfooding", "B", WAGRConfigGroupDogfood, "WhatsApp", "HNDogfooding"),
    WAGR_CONTROL("ios_internal_in_app_bug_reporting_enable", "Bug reporting interno no app", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("ios_internal_rage_shake_enabled", "Rage Shake interno", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("internal_bug_reporting_simplified", "Formulário interno simplificado", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("internal_bug_reporting_bottom_sheet", "Bug reporting em bottom sheet", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("get_help_internal_bug_report_enabled", "Reportar bug interno em Ajuda", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("show_fishfooding_toggle_in_bug_reporting_form", "Mostrar opção fishfooding no formulário", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("give_dogfooders_task_id_for_bug_reporting", "Task ID no relatório de bug", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAInAppSupport"),
    WAGR_CONTROL("private_abprop_for_dev_only", "Propriedade privada de desenvolvimento", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAPrivateExperimentation"),
    WAGR_CONTROL("internal_group_indicator", "Indicador de grupo interno", "B", WAGRConfigGroupInternalTools, "WhatsApp", "WAGroupAndContactInfo"),
    WAGR_CONTROL("mc_push_gating", "Gate de atualização MC por push", "B", WAGRConfigGroupABProps, "SharedModules", "SilentPush"),
    WAGR_CONTROL("group_ab_props", "ABProps de grupos", "B", WAGRConfigGroupABProps, "SharedModules", "WAPropertiesShared"),
    WAGR_CONTROL("ios_abprops_blocking_ui_offline_resume", "ABProps bloqueantes no retorno offline", "B", WAGRConfigGroupABProps, "SharedModules", "WANetworkingObjCABProps"),
    WAGR_CONTROL("ios_abprops_prevent_wablocktasks_during_offline_resume", "Evitar tarefas bloqueantes no retorno offline", "B", WAGRConfigGroupABProps, "SharedModules", "WANetworkingObjCABProps"),
    WAGR_CONTROL("ios_tigon_mns_bug_report_enabled", "Diagnóstico MNS no bug report", "B", WAGRConfigGroupTransport, "SharedModules", "WATigonObjCABProps"),
    WAGR_CONTROL("ios_tigon_canceller_enabled", "Cancelamento de requests Tigon", "B", WAGRConfigGroupTransport, "SharedModules", "WATigonObjCABProps"),
    WAGR_CONTROL("ios_tigon_quic_handshake_timeout_seconds", "Timeout de handshake QUIC (s)", "q", WAGRConfigGroupTransport, "SharedModules", "WATigonObjCABProps"),
    WAGR_CONTROL("ios_tigon_tcp_secure_connection_timeout_seconds", "Timeout da conexão TCP segura (s)", "q", WAGRConfigGroupTransport, "SharedModules", "WATigonObjCABProps"),
};
#undef WAGR_CONTROL

static inline size_t WAGRConfigControlCount(void) {
    return sizeof(kWAGRConfigControls) / sizeof(kWAGRConfigControls[0]);
}
static inline const WAGRConfigControlDefinition *WAGRConfigControlAt(size_t index) {
    return index < WAGRConfigControlCount() ? &kWAGRConfigControls[index] : NULL;
}
static inline const WAGRConfigControlDefinition *WAGRConfigControlFind(const char *selector) {
    if (!selector) return NULL;
    for (size_t i = 0; i < WAGRConfigControlCount(); ++i)
        if (!strcmp(selector, kWAGRConfigControls[i].selector)) return &kWAGRConfigControls[i];
    return NULL;
}
static inline const char *WAGRConfigControlGroupTitle(WAGRConfigControlGroup group) {
    const char *titles[] = {"MobileConfig / sincronização", "ABProps ↔ MC / diagnóstico",
        "Dogfood / nudges", "Internal / ferramentas", "ABProps / atualização", "Tigon / transporte"};
    return group >= 0 && group < WAGRConfigGroupCount ? titles[group] : "Configurações";
}
static inline bool WAGRConfigControlCatalogBuildMatches(const char *version, const char *build) {
    return WAGRWAABCatalogBuildMatchesCString("26.40.10", "1086609742", version, build);
}
