# AB Props native row replacement

Patch aplicado neste zip.

## Análise feita

- Headers enviados: `WADebugViewController` herda de `WAStaticTableViewController`. A tabela nativa é alimentada por datasource/delegate e por uma lista privada `sections`; mexer em `WATableSection`/`WATableRow` é risco de dessync.
- `WAStaticTableViewController` já expõe `tableView:numberOfRowsInSection:`, `tableView:cellForRowAtIndexPath:`, `tableView:didSelectRowAtIndexPath:`, header/footer e `sections`.
- Portanto o patch não muda contagem de seções/rows. Ele substitui somente a célula `section 0 / row 0`, que é a row do yellow card de AB Props no build atual.
- LIEF confirmou o Mach-O principal arm64 e seções `__TEXT,__text`, `__objc_methname`, `__objc_selrefs`, `__objc_classlist`, Swift metadata e `__cstring`. Capstone/llvm-objdump foram usados em torno de `WADebugViewController createSections` candidato `0x101737dcc`; a função é grande e monta o menu nativo por helpers, então o ponto estável para UI é o datasource hook.

## Alterações

- `src/Hooks/WAGRDebugMenuInstrumentation.xm` agora intercepta `WADebugViewController` `section=0,row=0` e retorna uma célula própria `WATweaks AB Props Browser`.
- O tap nessa mesma row abre `WAGRABPropsRootVC`.
- O footer da seção 0 é substituído por uma explicação do patch para não deixar a mensagem antiga de TestFlight/Debug build confundindo.
- `src/Menu/WAGRABPropsRootVC.h/.m` adiciona um browser AB Props organizado por seções: AB Props, categorias principais e infra/diagnóstico.

## O que não foi feito de propósito

- Não aumenta `numberOfSectionsInTableView:`.
- Não aumenta `tableView:numberOfRowsInSection:`.
- Não cria `WATableSection` ou `WATableRow`.
- Não lê campos Swift por offset dinâmico.
