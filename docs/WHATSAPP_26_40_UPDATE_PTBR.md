# WhatsApp 26.40.10: atualização de AbProps, MobileConfig e browser

Alvo analisado na sessão: `net.whatsapp.WhatsApp`, versão 26.40.10,
build1086609742, arm64. Base: dogfood2/0466dff.
Foram extraídos o payload e inventariadas17 imagens Mach-O. A investigação
com LIEF/Capstone e Ghidra12.1.4/JDK25 foi direcionada aos fluxos relevantes,
não à decompilação completa de todas as funções.

## Defeitos confirmados

| Área | Evidência nativa / comportamento corrigido |
|---|---|
| Fetch MC | `WAChatManager.fetchMobileConfig:` não existe no alvo. Método atual: `fetchMobileConfig:stack:`, ABI `v24@0:8B16i20`, IMP0x1004ae184. Chamador nativo0x102d7a318 passa `NO,-1`; preservar seleção nativa do backend. |
| Refresh MC | `forceInvalidate` (0x5e3298) é teardown: disposed=1, config manager zerado, callbacks/observadores removidos; também chamado por dealloc. Refresh comum agora usa somente `invalidateCachedLatestContext`. |
| Callback ABT | Bloco0x4fa87c entrega três argumentos, primeiro success e segundo didChange; terceiro objeto associado ao resultado/configKey na análise. Wrapper antigo descartava argumentos. Preservar os três, registrar payload e exigir sucesso nativo. |
| Confirmação MC | Resposta XWA sem erro não comprova persistência. Exigir marcador nativo da mesma unidade/store. Manager do fetch vem estritamente de `context.abProperties.mc`, não do último manager global de outra conta. |
| Browser | Inventário dependia de getters ObjC e renderização podia executar métodos arbitrários. Agora lista imagens carregadas/incorporadas independentemente de getters; navegar/filtrar usa cache e metadados. Leitura é explícita. |

Há testes para seleção do contrato MC e stack automático(-1), identidade da
unidade/contexto, proibição de teardown no refresh, encaminhamento do callback,
resultado nativo negativo, seletores de ciclo de vida/ações e inventário de
frameworks aninhados/dormentes. Overrides tipados continuam disponíveis.
Removidos os probes passivos e as tentativas de fabricar receivers por factories
ou caminhar ivars arbitrários. Não há `dlopen` para forçar frameworks dormentes.

## Fluxos e persistência

AbProps: contexto da conta → XMPPConnectionABPropsRequestManager →
WAABPropsRequestBuilder → XMPPRequestABProperties(namespace abt) → conexão
nativa/autenticada → decoder/handler → WAProperties/WAPropertiesStore.
IMPs sem ASLR: request0x4fa998; lower0x4fa608; builder0x70dce8;
request initializer0x70de74; decoder0x70e10c; handler0x70e4f8.
Assinaturas e offsets do store usados pela branch permanecem válidos neste build.
O BOOL é deltaUpdate, não um parâmetro de eligibility. NO sozinho não força full:
o hash atual pode resultar em resposta sem mudanças. O serviço full existente
esvazia o hash pelo método nativo e exige resposta/handler/store correlacionados.
O callback negativo não pode ser transformado em sucesso por um cache anterior.

MC: `WAChatManager.fetchMobileConfig:stack:` → `runWhenConnected:` →
WAMobileConfigTask → backend escolhido pelo app. Stack -1 é unset/automático;
0=erlang,1=www,2=ig_server. Contextos UserSession, sessionless e guest são
unidades distintas. Tokens/validadores e seleção de backend permanecem nativos.
Marcar sucesso exige o marcador persistido da unidade ativa, não qualquer evento
global ou uma resposta de outra conta.

Os dois sistemas coexistem com tradução via WAMCEvaluation: stableID ABProp →
paramSpecifier → manager MC vivo → ID externo da config e índice do parâmetro.
Esses IDs não são intercambiáveis. Fetch ABT não gera mc_overrides.json.
Os caminhos físicos devem vir de getLatestConfigFilePath/getOverridesTablePath.
O parser nativo aceita mapa configID:nome → array de strings
`indice: nome: valor`, com ramo especial `_qe_overrides_`. Isso comprova a leitura,
não a ativação segura por reescrita manual. `setOverrides:` usa shared_ptr C++;
não pode receber NSDictionary via objc_msgSend. Writer compatível continua
bloqueado; overrides existentes usam StartupConfigs e confirmação nativa.

Psiphon oferece túnel/proxy/GoPsi. Não foi encontrada evidência de que seja o
store ou protocolo de download de flags. Frameworks CommonLibrary, Psiphon,
WSVendor, FLEX/InMobi e bibliotecas injetadas podem estar incorporados sem ainda
estarem carregados. Extensões têm seus próprios processos.

## Evidência e validação

SharedModules analisado: SHA256
`48f3e91d8db16c6c7203ad5331aeb4e1642010cff06639ef6528206ec71769f1`,
UUID`4c4c44a0-5555-3144-a142-002d3eaa13a4`.
Os endereços acima são referências da análise estática da sessão, não offsets
executados pelo patch. Dispatch/hooks são resolvidos por seletor/ABI; diagnóstico
ABT identifica separadamente UUID/build do processo instalado.

```sh
python3 scripts/wagr_validate_sources.py
python3 scripts/wagr_validate_sideload_hooks.py
python3 scripts/wagr_validate_cold_start.py
python3 scripts/wagr_validate_abprops_fetch.py
python3 scripts/wagr_test_abt_completion.py
python3 scripts/wagr_test_mobileconfig_fetch.py
python3 scripts/wagr_validate_runtime_browser.py
```

Contratos C compilados e validação de integração não substituem compilação iOS,
instalação ou sessão de rede real. O build completo usa o workflow dogfood2.
Eligibility do servidor e recebimento real dos dados não podem ser certificados
somente por strings, flags locais ou pelo sucesso dos testes no host.

Arquivos privados de containers/contas Facebook não fazem parte deste patch de
WhatsApp e não são publicados neste repositório.
