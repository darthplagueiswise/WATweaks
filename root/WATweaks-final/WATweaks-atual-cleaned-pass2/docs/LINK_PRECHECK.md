# Link precheck — WATweaks

Este documento cobre erros que só aparecem depois que todos os arquivos compilaram, na etapa de link.

## 1. Um símbolo C público deve ter um único dono

Qualquer função declarada como `extern "C"` e não marcada como `static` vira símbolo global no binário. Se duas `.xm/.m` implementarem a mesma função, o linker falha com `duplicate symbol`.

Exemplo real:

```text
duplicate symbol '_WAGRPushAuraThemesVC'
  WAAuraHooks.xm.o
  WAGRAuraNavigationHooks.xm.o
```

Correção aplicada:

- `WAGRAuraNavigationHooks.xm` é dono de navegação Aura e bulk flags:
  - `WAGRPushAuraThemesVC`
  - `WAGRPushAuraIconsVC`
  - `WAGRPushAuraRingtonesVC`
  - `WAGROpenSubscriptionsNative`
  - `WAGRAuraActivateAllFlags`
  - `WAGRAuraDeactivateAllFlags`
  - `WAGRAuraSimulationEnabled`

- `WAAuraHooks.xm` é dono apenas dos hooks de gating Aura:
  - `WAGRAuraGatingSwiftHooksInstall`
  - `WAGRAuraEnsureHooksInstalled`
  - `WAGRAuraDiagnostic`

- `WAABPropsObserver.xm` é dono de:
  - `WAGRWAABEnsureHooksInstalled`

- `WAGRRuntimeCompat.m` não pode duplicar símbolos que já têm dono real.

## 2. Como procurar duplicação antes do push

Use `grep` para listar definições globais `extern "C"`:

```sh
grep -R "extern \"C\"" -n src | sort
```

Para símbolos específicos que já deram problema:

```sh
grep -R "extern \"C\" .*WAGRPushAuraThemesVC\|extern \"C\" .*WAGRAuraActivateAllFlags\|extern \"C\" .*WAGRWAABEnsureHooksInstalled\|extern \"C\" .*WAGRAuraSimulationEnabled" -n src
```

Cada função deve aparecer como implementação em apenas um arquivo. Declarações sem corpo são permitidas, por exemplo:

```objc
extern "C" BOOL WAGRAuraSimulationEnabled(void);
```

Implementações com corpo devem ser únicas:

```objc
extern "C" BOOL WAGRAuraSimulationEnabled(void) {
    return WAGRPref(kWAGRAuraSimulation);
}
```

## 3. Regra para compat shims

Arquivos de compatibilidade só podem implementar símbolos que não existem em nenhum outro arquivo.

Antes de adicionar um shim em `WAGRRuntimeCompat.m`, buscar:

```sh
grep -R "NomeDoSimbolo" -n src
```

Se já existir implementação real em `Hooks/`, o compat deve apenas declarar `extern`, ou não tocar no símbolo.

## 4. Regra de ownership por domínio

- Gate runtime genérico: `WAGRGateHooks.xm`
- WAAB bool/string key hooks: `WAABPropsObserver.xm`
- Aura gating: `WAAuraHooks.xm`
- Aura navegação / telas / bulk flags: `WAGRAuraNavigationHooks.xm`
- Native Developer Menu: `WAGRNativeDevMenuHooks.xm`
- Settings rows: `WAGRSettingsRowsNativeHooks.xm`
- Runtime browser UI: `WAGRSurfaceBrowserVC.m`

Não mover função pública entre donos sem remover a implementação antiga.
