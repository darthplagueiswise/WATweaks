# Build precheck — WATweaks

Este checklist existe para evitar exatamente o erro de build em que uma alteração de arquitetura remove uma tela/helper, mas algum arquivo antigo continua importando ou compilando contra ela.

## 1. Nunca aplicar patch parcial sem conferir dependências

Antes de subir qualquer zip/patch, rode uma busca por todos os símbolos removidos. Se um arquivo for removido, nenhum `#import`, chamada, enum, constante ou função dele pode continuar em `src/`.

Exemplo do erro que motivou este documento:

```text
#import "WAGRSurfaceBrowserVC.h"
fatal error: 'WAGRSurfaceBrowserVC.h' file not found
```

O patch removeu telas duplicadas de gating, mas deixou o caminho `Runtime Avançado` usando `WAGRSurfaceBrowserVC`. A correção correta não era restaurar `WAGRGatingCatalog`/`WAGRGatingAreaMenuVC`, e sim manter somente o browser usado pelo caminho único.

## 2. Verificar headers antes de compilar

Para cada `.m`/`.xm`, confirme que todo `#import "..."` existe no repo depois do patch.

Comando recomendado:

```sh
python3 - <<'PY'
from pathlib import Path
import re
root = Path('src')
missing = []
for f in list(root.rglob('*.m')) + list(root.rglob('*.xm')) + list(root.rglob('*.x')) + list(root.rglob('*.h')):
    text = f.read_text(errors='ignore')
    for m in re.finditer(r'#import\s+"([^"]+)"', text):
        inc = m.group(1)
        target = (f.parent / inc).resolve()
        if not target.exists():
            missing.append((str(f), inc))
if missing:
    for f, inc in missing:
        print(f'MISSING IMPORT: {f} -> {inc}')
    raise SystemExit(1)
print('imports OK')
PY
```

## 3. Verificar símbolos removidos

Sempre buscar por símbolos obsoletos depois de deletar arquivos ou trocar arquitetura.

```sh
grep -R "WAGRGatingCatalog\|WAGRGatingAreaMenuVC\|WAGROverrideKey\|kWAGRSurface" -n src || true
```

Estado esperado após a unificação do menu:

- `WAGRGatingCatalog.*`: ausente.
- `WAGRGatingAreaMenuVC.*`: ausente.
- `WAGRSurfaceBrowserVC.*`: presente, porque é usado pelo caminho único `Runtime Avançado`.
- `kWAGRSurface*`: não deve ser necessário em `WAGRSurface.m`; usar strings locais como `@"waab"`, `@"context"`, etc.
- `WAGROverrideKey`: não deve ser usado pelo Runtime Avançado novo; usar `WAGRGateStore`/`WAGRGateSet`/`WAGRGateClear`.

## 4. Não contrariar a decisão de UI única

A UI de gating deve ter um único caminho bruto:

```text
WATweaks -> Avançado -> Runtime Browser Avançado -> Surface técnica -> Toggle
```

Não reintroduzir:

- Seção `Categorias`.
- Seção `Áreas de Gating (Curadas)`.
- `WAGRGatingCatalog`.
- `WAGRGatingAreaMenuVC`.

Se precisar corrigir build, corrija o caminho único. Não restaure telas duplicadas.

## 5. Runtime Avançado deve usar o store canônico

O browser bruto deve escrever no store central:

```objc
WAGRGateSet(selectorName, YES/NO);
WAGRGateClear(selectorName);
WAGRGateIsSet(selectorName);
WAGRGateGet(selectorName);
WAGRGateInstallHookForSelector(className, selectorName, isClassMethod);
```

Não usar storage antigo:

```objc
WAGRSetOverride(...)
WAGRClearOverride(...)
WAGROverrideBool(...)
WAGRHasOverride(...)
WAGROverrideKey(...)
```

## 6. Constructor/hot path

Constructor só pode instalar hooks fixos e baratos.

Permitido:

```text
NSClassFromString
class_getInstanceMethod/class_getClassMethod
MSHookMessageEx
fishhook/rebind_symbols
registro de observer leve
```

Proibido no constructor:

```text
objc_copyClassList
class_copyMethodList em massa
NSUserDefaults dictionaryRepresentation
synchronize
runtime browser/probe
userContext/session lookup
UIKit navigation real
```

## 7. Makefile compila tudo em `src`

O Makefile usa:

```make
find src -type f \( -iname *.x -o -iname *.xm -o -iname *.m \)
```

Então qualquer `.m` ou `.xm` deixado em `src` será compilado. Arquivo morto não pode ficar no diretório. Se uma tela foi removida, apagar `.h` e `.m`; se um `.m` depende de header removido, corrigir ou apagar o `.m` também.

## 8. Preflight local obrigatório antes de push

Antes de subir para `dev`, rode pelo menos:

```sh
git status --short
python3 scripts/wagr_validate_sources.py || true
grep -R "WAGRSurfaceBrowserVC.h" -n src/Menu/WAGRSurfaceListVC.m src/Menu/WAGRSurfaceBrowserVC.h src/Menu/WAGRSurfaceBrowserVC.m
grep -R "kWAGRSurface\|WAGROverrideKey" -n src/Runtime src/Menu || true
```

Se o build falhar por `file not found`, `undeclared identifier` ou `implicit function declaration`, não é problema do Theos. É patch incompleto ou header/API removida sem atualizar os callers.

## 9. Workflow

O workflow de build da branch de desenvolvimento deve apontar para `dev`:

```yaml
on:
  push:
    branches:
      - 'dev'
```

Sempre conferir isso antes de enviar zip/patch para iSH.
