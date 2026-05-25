# WATweaks — Refactor (schema v2)

## Resumo do que mudou

### Storage unificado
- Toda override de gate agora é uma chave plana `<selectorName>` no `NSUserDefaults`, valor `NSNumber BOOL`.
- Ausência de chave = sem override (fallback ao valor original do app).
- API única em `src/Runtime/WAGRGateStore.{h,m}`: `WAGRGateIsSet/Get/Set/Clear/AllOverrides/ClearAll`.
- `WAGRWipeLegacyStorageIfNeeded()` roda uma vez no `__attribute__((constructor))` do `WAGRGateHooks.xm` e remove o que estava nos prefixos legados:
  - `wagr.waab.*`
  - `wagr.override|*` / `wagr.override.*`
  - `wagr.observed|*` / `wagr.observed.*`
- Marker `wagr.storage.wiped.v2 = YES` garante que o wipe só roda uma vez.

### Hooks
- **`src/Hooks/WAGRGateHooks.xm`** (novo) é o único dono dos hooks de gate. No constructor:
  1. Roda o wipe legado.
  2. Instala `boolForKey:defaultValue:` e `stringForKey:defaultValue:` em `WAABProperties` e `FOAWAABPropertiesImpl` — uma única trampolim por classe cobre milhares de flags AB.
  3. Instala hooks específicos só nos selectors confirmados em dump (Aura, MobileConfigGating, WAServerProperties class methods).
  4. Re-instala hooks para overrides persistidos de sessões anteriores.
  5. Registra `_dyld_register_func_for_add_image` + 3 retries (0.25s/0.75s/2s) para classes Swift que carregam tarde.
- **`WAGRGateInstallHookForSelector(className, sel, isClassMethod)`** é exportado para o runtime browser instalar hooks on-demand quando o usuário liga um flag.
- **`src/Hooks/WAGRAuraNavigationHooks.xm`** (novo) tem só a parte de navegação que estava no antigo `WAAuraHooks.xm`: factory hooks de `WAAppearanceSettingsViewController`, injeção de `userContext`, helpers `WAGRPushAura{Themes,Icons,Ringtones}VC`, `WAGRAuraActivate/DeactivateAllFlags`, e `WAGRAuraSimulationEnabled`.
- Removidos: `WAGRObjCHookRouter.xm`, `WAABPropsObserver.xm`, `WAAuraHooks.xm` — toda a função desses três foi consolidada em `WAGRGateHooks.xm` + `WAGRAuraNavigationHooks.xm`.

### UI — categorias com runtime drill-down
A árvore do menu raiz (`WAGRSurfaceListVC`) agora é só:
1. **Menu Developer Nativo** — lança `WADebugViewController`.
2. **Menus Secretos** — Internal/Aura simulation + Debug VC Lab (sem mudanças funcionais).
3. **Runtime Gates** — abre o novo browser unificado.
4. **Sobre**.
5. **Sistema** — backup/restart/reset.

O **Runtime Gates** (`WAGRRuntimeGatesVC`) lista as categorias declaradas em `WAGRGateRegistry`:
- Server Properties, WAAB Properties, LiquidGlass, Aura, MobileConfig, WAContext, FOA, Biz, Settings.
- Cada categoria tem `featured` flags (os "dials" conhecidos) e fragmentos de classe para o scan runtime.

Ao tocar numa categoria, abre **`WAGRGateCategoryVC`**:
- Featured flags com `UISwitch` direto. Toggle ON aciona `WAGRGateSet(name, YES)` + tenta `WAGRGateInstallHookForSelector` em cada classe candidata da categoria.
- Long-press na linha limpa o override (volta ao comportamento original).
- Botão **"Runtime Avançado"** abre `WAGRGateRuntimeBrowserVC`.

O **`WAGRGateRuntimeBrowserVC`** faz `objc_copyClassList` + `class_copyMethodList` por classe candidata, filtra BOOL no-arg + tokens de seleção da categoria, e mostra:
- Uma seção por classe.
- Cada selector com `UISwitch` (label `+ selector` para class method, `- selector` para instance).
- Search bar para filtro por classe ou selector.
- Long-press para limpar override / copiar selector.
- Botão de reset da categoria no topo direito.

Exemplo do caso citado (LiquidGlass M1.5):
- Em **LiquidGlass / WDS**, deixar `ios_liquid_glass_enabled` ON.
- Deixar `ios_liquid_glass_m_1_5` OFF (toggle explícito).
- Cada chave é independente; nenhum master sobrescreve o outro.

### Arquivos modificados (adaptados ao schema v2)
- `src/Tweak.x` — removeu externs antigos (`WAGRWAABEnsureHooksInstalled`, `WAGRAuraEnsureHooksInstalled`, `WAGRReinstallPersistedHooks`, `WAGRHookRouterDiagnostic`), passou a chamar `WAGRGateHooksEnsureInstalled` + `WAGRAuraEnsureNavigationHooksInstalled`.
- `src/Hooks/WAGRAccountEligibilityHooks.xm` — leitura do override agora via `WAGRGateIsSet/Get` (chave = selectorName).
- `src/Hooks/WAGRNativeDevMenuHooks.xm` — idem para `isDebugMenuAllowed`/`isDebugMenuShortcutEnabled`.
- `src/Hooks/WAGRSettingsRowsNativeHooks.xm` — `WAGRWAABAnyOn` usa `WAGRGateIsSet+Get`; bootstrap chama os novos `Ensure...`.
- `src/Menu/WAGRSecretMenusVC.m` — toda lógica de master toggle reescrita para schema v2; diagnósticos apontam para `WAGRGateHooksDiagnostic` / `WAGRAuraNavigationDiagnostic`.
- `src/Menu/WAGRDebugVCInstantiatorVC.m` — externs e chamadas atualizados.
- `src/Menu/WAGRSettingsBackup.m` — externs e chamadas atualizados.
- `src/WAGramPrefix.h` — enxuto: define só master prefs e dogfood gate keys; importa `Runtime/WAGRGateStore.h`. Removeu macros legados `WAGRKey`, `WAGRIsOn`, `WAGRIsOff`, `WAGROverrideKey`, `WAGRHasOverride`, `WAGROverrideBool`, `WAGRSetOverride`, `WAGRClearOverride`.

### Arquivos removidos
- `src/Hooks/WAGRObjCHookRouter.xm`
- `src/Hooks/WAABPropsObserver.xm`
- `src/Hooks/WAAuraHooks.xm`
- `src/Menu/WAGRSurfaceBrowserVC.{h,m}`
- `src/Menu/WAGRGatingAreaMenuVC.{h,m}`
- `src/Menu/WAGRGatingCatalog.{h,m}`
- `src/Runtime/WAGRSurface.{h,m}`
- `src/Runtime/WAGRObjectGraphScanner.{h,m}`

### Arquivos novos
- `src/Runtime/WAGRGateStore.{h,m}`
- `src/Runtime/WAGRGateRegistry.{h,m}`
- `src/Hooks/WAGRGateHooks.xm`
- `src/Hooks/WAGRAuraNavigationHooks.xm`
- `src/Menu/WAGRRuntimeGatesVC.{h,m}`
- `src/Menu/WAGRGateCategoryVC.{h,m}`
- `src/Menu/WAGRGateRuntimeBrowserVC.{h,m}`

## Notas de build

O `Makefile` usa `find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \)`, então os novos arquivos são pegos automaticamente. Nenhuma mudança no Makefile.

## Notas de launch / estabilidade

- O constructor do `WAGRGateHooks.xm` é deliberadamente leve: não faz `class_copyMethodList` em massa. Toda introspecção de runtime acontece sob demanda via o browser, fora do startup path.
- Cada `__attribute__((constructor))` é idempotente, registra callback dyld, e tem 3 retries staged. Classes Swift carregadas tarde (típico em SharedModules) caem nesse caminho sem ficar com hooks faltando.
- O wipe legado roda uma vez por instalação; o marker `wagr.storage.wiped.v2` impede repetição em launches subsequentes.
- A trampolim genérica de BOOL no-arg (`WAGRGateGenericBoolTrampoline`) é compartilhada entre selectors e dispatch por (class, selector) — uma tabela hash em `gGateOriginalIMPs`, sem custo por chamada além do lookup.
- A trampolim de `boolForKey:defaultValue:` cobre o leitor universal de flags AB; uma instalação por classe = todos os flags AB cobertos, sem precisar de hook per-flag.
