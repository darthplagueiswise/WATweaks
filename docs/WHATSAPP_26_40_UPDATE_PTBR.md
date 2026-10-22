# WhatsApp 26.40.10: ABProps, MobileConfig e runtime

Alvo: `net.whatsapp.WhatsApp`, versão `26.40.10`, build `1086609742`, arm64.
SHA-256 da IPA analisada:
`9c47c088a67a5e517adb2545f2719eb07f1e6dd43af183f27fde99d9ec281687`.

O Payload da IPA do WhatsApp foi extraído e suas 17 imagens Mach-O foram
inventariadas. A análise combinou metadata Objective-C, LIEF, Capstone e Ghidra
12.1.4/JDK 25. O ZIP de Facebook enviado por engano não foi usado. Esta é uma
análise estática dirigida aos fluxos relevantes; não é uma decompilação completa
de todas as funções e não inclui dump de memória de um processo em execução.

O build e os testes de host validam compilação e contratos locais. Não houve
execução no iPhone nem confirmação de resposta dos servidores. Em particular,
ativação employee/internal e download de nomes ainda não foram demonstrados.

## Falha reportada: getMCSpecifierForStableId

O log `WAMCEvaluation.getMCSpecifierForStableId: não está disponível com ABI
compatível` revelou uma incompatibilidade que a primeira revisão deixou passar.
Esse selector não existe na metadata da IPA 26.40.10. A dependência afetava cinco
consumidores: crosswalk MC, resolução de nomes, enriquecimento do store, overrides
StartupConfigs e correlação do browser. Isso é uma falha local de tradução de
IDs; o log isolado não prova rejeição de eligibility ou erro de rede.

O substituto confirmado é `+getWAStableIdToParamSpecifierEntries`, ABI
`r^v16@0:8`. Retorna ponteiro para `{const uint64_t *entries, uint64_t count}`,
não um objeto Objective-C. O consumidor `WAPushPropertiesManager` verifica
`stableID < count` antes de consultar `entries[stableID]`. A tabela desta IPA tem
38.805 posições, com 13.747 descritores não nulos; o limite antigo de 34.666
truncava o domínio.

Os cinco consumidores agora partilham esse leitor: valida ABI e build, copia a
estrutura/tabela com `mach_vm_read_overwrite`, rejeita limites inválidos e mantém
um snapshot imutável. Falha de inicialização não fica em cache. Não há offsets
fixos de funções na implementação. Outras builds exigem validação do layout,
porque `const void *` sozinho não descreve a estrutura.

Evidência adicional, reproduzida com Capstone a partir dos bytes da IPA:

| Imagem / endereço virtual | Evidência |
|---|---|
| SharedModules `0x1cfbd4` | Getter Objective-C atual; resolve a função de schema pelo ID `0xe69`. |
| WhatsApp `0x107b97fe0` | Registro da feature `0x0a076f93`; aponta para schema em `0x105df6190`. |
| WhatsApp `0x105df6190` | Quarto `uint32_t` do schema é `0xe69`. |
| SharedModules `0x3949248` | Entrada do dispatcher para `0xe69 - 0xd9e`, aponta para `0x1cfc0c`. |
| SharedModules `0x1cfc0c` | Inicializa o span com tabela `0x29062f0` e count `0x9795` (38.805). |
| SharedModules `0x1d44c8` | Lookup nativo usa a mesma tabela e limite `0x9794`. |
| SharedModules `0x111ceb0`–`0x111cf80` | Consumidor lê ponteiro/count e faz lookup de 8 bytes por stable ID. |

Esses endereços documentam esta IPA; não são usados como endereços de runtime.

Também foi confirmado um vínculo estático real com Psiphon: o dispatcher
`XPluginsGetFuncPtr` no executável trata ID `0xd9d` carregando
`XPluginsGetFunctionInPsiphonTunnel`; no framework, a função exportada
(`0x55df3c`) aceita índice 0 e devolve `0x55dfe8`, que chama
`ProxyServiceImpl +sharedInstanceWithConfig:`. Isso demonstra integração de
proxy, não que Psiphon produza hashes MC ou controle eligibility. Não houve dump
de memória nem teste de tráfego pelo túnel.

## Resultado das correções

| Área | Causa | Correção |
|---|---|---|
| Fetch ABProps | O pedido nativo era bloqueado se qualquer hook de correlação/observação não instalasse. | Os observers agora são best-effort e passivos. O request nativo preserva seu ABI e é enviado mesmo sem telemetria completa. |
| Fetch MobileConfig | O código exigia observer XWA2/success marker antes de chamar `fetchMobileConfig:stack:`, embora o app também possa escolher WWW. | O dispatch nativo não depende de observers. O diagnóstico separa dispatch, FetchPlan, rota, request, marcador e persistência. |
| Runtime browser | A tela principal tinha só dois atalhos fixos e cada toque fazia scan global síncrono. | Um hub único enumera todas as imagens do processo principal, faz scan em background e mantém cache por geração do dyld. |
| Famílias | O nome era inferido apenas pelos tokens do selector. | Catálogo da build com 12.241 selectors e categorias Objective-C extraídas da IPA; fallback heurístico fica marcado como `Fallback ·`. |
| Dogfood | O launcher tentava controllers ausentes e fabricava gates internal/employee. | Usa apenas `https://fburl.com/df_iphone`, confirmado na build, e mostra identidade/gates somente para diagnóstico read-only. |

## As quatro rotas nativas

### 1. ABProps/ABT autenticado por XMPP

Fluxo observado:

`userContext` → `XMPPConnectionABPropsRequestManager` →
`WAABPropsRequestBuilder` → `XMPPRequestABProperties` (`namespace=abt`) →
conexão autenticada → decoder/handler → `WAPropertiesStore`.

O entrypoint superior é `requestFreshABProps:withCompletion:` com ABI
`v28@0:8B16@?20`. Ele chega ao método
`requestFreshABPropsWithGroupJID:deltaUpdate:completion:` com ABI
`v36@0:8@16B24@?28`. O callback entrega
`(success, didChange, configKey)`; nenhum desses valores pode ser descartado ou
substituído por evidência de outro request.

O BOOL é `deltaUpdate`, não eligibility. No full request, o protocolo usa o
`configHash`; no delta, usa `refreshID`, com `"0"` como default. Um callback
negativo continua sendo falha mesmo que exista cache antigo. O servidor ainda
decide elegibilidade e conteúdo para a conta autenticada.

### 2. MobileConfig autenticado/account session

O entrypoint atual é `fetchMobileConfig:stack:` com ABI `v24@0:8B16i20`.
O chamador nativo padrão passa `NO, -1`; `-1` deixa a seleção de stack/backend
para o próprio app. O FetchPlan nativo decide se haverá rede e qual rota será
usada. O caminho WWW autenticado exige credenciais canônicas do usuário com a
feature `mobile_config`; XWA2 permanece uma rota possível da sessão.

### 3. MobileConfig sessionless

É um pipeline distinto, com autenticação estática proveniente de
`WAGraphQLStaticAuthTokens.staticAT`. Não deve receber credenciais inventadas,
nem ser tratado como prova de que a rota account-scoped funcionou.

### 4. MobileConfig guest

Também possui unidade e ciclo próprios. Eventos de guest/sessionless não podem
confirmar o fetch ou a persistência da unidade autenticada.

## Hash, one_query, BLN e retry

`one_query_hash`, `one_query_string`, `bln_li_hashes`, `bln_queries`,
`global_value_hash` e `ep_refresh_id` pertencem ao protocolo GraphQL do
MobileConfig, não ao ABT/XMPP. A build registra os erros
`UnknownOneQueryHash`, `OneQueryHashError` e `BlnQueriesError`. Quando o servidor
rejeita o hash conhecido, o cliente pode repetir com o `one_query_string`
completo. Portanto, WATweaks apenas observa esses inputs; não calcula nem injeta
hashes.

Os estados diagnósticos agora distinguem:

- `native_entrypoint_dispatched_waiting_fetch_plan_or_network`;
- timeout antes de qualquer request;
- timeout após request WWW;
- timeout após request XWA2;
- success marker e persistência da mesma unidade/account.

Isso evita diagnosticar ausência de XWA2 como falha quando o FetchPlan escolheu
WWW, ou confundir “nenhuma rede necessária” com erro de chamada.

## Persistência, download e overrides MobileConfig

`id_name_mapping.json`, `qe_info.json` e `mc_overrides.json` são artefatos do
repositório MobileConfig nativo. A análise não comprovou endpoint independente
para “baixar `id_name_mapping.json`”. Ele é materializado/consumido como parte do
ciclo de config da unidade. Os caminhos corretos vêm dos resolvers nativos, como
`getLatestConfigFilePath` e `getOverridesTablePath`; não devem ser reconstruídos
com um UDID/UIDD presumido.

Não foi encontrada evidência de que UDID ou uma chave chamada UIDD seja input
direto desses entrypoints. A evidência aponta para contexto de conta/sessão,
credenciais canônicas ou static auth, conforme a rota. Um problema de identidade
de unidade deve ser verificado pelo `userContext` e pela unidade/store correlata,
não corrigido inventando um identificador de dispositivo.

O parser nativo lê o mapa `configID:nome` e linhas no formato
`indice: nome: valor`, com ramo `_qe_overrides_`. `mc_overrides.json` é controlado
por `FBMobileConfigOverridesTable`; o setter usa `shared_ptr` C++. Escrever o JSON
diretamente ou passar `NSDictionary` por `objc_msgSend` é ABI incorreto e pode
corromper o processo. Por isso:

- artefatos MC nativos são exibidos/exportados read-only;
- o WATweaks não reescreve `mc_overrides.json`;
- overrides locais suportados continuam na camada `StartupConfigs`/stores
  próprios, com confirmação nativa;
- overrides de getters feitos pelo WATweaks continuam separados e identificados.

MobileConfig vira source of truth apenas quando o status nativo não é 0, 1, 2 ou
4, `gating.isSourceOfTruth` está ativo e não há emergency rollback. Uma simples
resposta HTTP/GraphQL não comprova essa transição.

## Como ABProps e MobileConfig se relacionam

Eles não são dois downloads do mesmo arquivo. ABT entrega propriedades pelo
pipeline XMPP; MC entrega configurações pelo pipeline MobileConfig/GraphQL.
`WAMCEvaluation` faz a ponte de avaliação:

`stableID ABProp` → `paramSpecifier` → manager MC da unidade → config ID externo
e índice do parâmetro.

Esses identificadores não são intercambiáveis. Fetch ABT não gera
`mc_overrides.json`; fetch MC não substitui o callback/configHash do ABT. A
“coligação” acontece na avaliação e resolução de parâmetros, respeitando a
source-of-truth vigente e a unidade/account ativa.

## Dogfood, internal/employee e famílias

O entrypoint dogfood verificável nesta build é o nudge de Settings tipo 140 com
URL `https://fburl.com/df_iphone`. As classes anteriormente presumidas para menu
developer/private experimentation não aparecem em nenhuma das 17 imagens
Mach-O; o tweak não tenta mais instanciá-las.

`isInternalUser` vem do estado de servidor/conta (`adm`) e respeita
`serverPropsDisableExperimental`. Isso não é equivalente a escolher stack MC,
nem garante eligibility para uma família de experimentos. O launcher só lê e
reporta esses estados; não os força.

O painel Eligibility Employee/Internal lê separadamente `WAServerProperties
+isInternalUser`, `WAABProperties -adm`, `-isMetaEmployeeOrInternalTester` e
`-is_meta_employee_or_internal_tester`. A metadata marca o primeiro getter
employee/tester como `DeprecatedABProps1`, portanto ele não é promovido a prova
única da identidade employee. Valor indisponível é registrado como tal, nunca
como falso. O snapshot acompanha tanto a transação ABT quanto a MC, sem criar um
gate extra que bloqueie a decisão nativa.

O resultado MC registra tamanho/mtime/existência de latest config,
`id_name_mapping.json` e `qe_info.json` antes e depois do fetch, a partir do
manager preso à conta. Fetch confirmado e nomes materializados são estados
separados; o botão de exportação entrega o artefato nativo quando ele existe.

As famílias agora vêm das categorias Objective-C reais de `WAABProperties` em
WhatsApp e SharedModules. Exemplos confirmados:

| Selector | Imagem | Família |
|---|---|---|
| `ios_pause_video_preview` | SharedModules | `WAMediaPlayer` |
| `bloks_theming_infra_enabled` | WhatsApp | `BloksExperiment` |

Quando mais de uma categoria implementa o mesmo selector, todas são preservadas
por imagem em vez de escolher arbitrariamente uma. O IMP do método identifica a
imagem que contribuiu uma categoria, mesmo quando a classe veio de outro Mach-O.
O catálogo só é autoritativo
quando versão e build do app em execução coincidem com `26.40.10 (1086609742)`;
metadata ausente ou de outra build degrada para fallback explicitamente marcado.
O empacotamento `.deb` instala o recurso em Application Support e o fluxo
`build-fast.sh` o copia para a raiz do app sideloaded.

## Frameworks, processos e Psiphon

Foram inventariadas 17 imagens Mach-O e 32.537 classes Objective-C, totalizando
308.070 métodos. No processo principal, a IPA contém nove imagens inspecionáveis:

1. WhatsApp;
2. WSVendor.framework;
3. OnlineNotify.dylib;
4. FLEX.framework;
5. SharedModules.framework;
6. zxPluginsInject.dylib;
7. CommonLibrary.framework;
8. PsiphonTunnel.framework;
9. InMobiSDK.framework.

Extensões rodam em processos separados e não são misturadas com o inventário do
processo principal. Imagens incorporadas, porém dormentes, aparecem como não
carregadas e não sofrem `dlopen` apenas para inspeção.

PsiphonTunnel expõe 53 classes e 402 métodos ObjC ligados a túnel/proxy/GoPsi.
Não foi encontrada API ObjC de ABProps ou MobileConfig nele. Isso não prova que
nenhum código nativo inferior possa influenciar transporte; apenas impede
atribuir a ele, sem evidência, o store ou o protocolo desses downloads. Não houve
dump de Psiphon em memória nesta sessão.

## Limites da validação

Os validators no host cobrem contratos de ABI, dispatch passivo, correlação por
transação/unidade, rotas MC, catálogo, segurança de selectors e inventário. Eles
não substituem build Theos, instalação em iPhone, conta elegível nem sessão real
de rede. Sucesso ao vivo só pode ser confirmado no dispositivo, observando o
callback nativo e a persistência da mesma unidade/account.

```sh
for test in scripts/wagr_test_*.py scripts/wagr_validate_*.py; do
  python3 "$test" || exit 1
done
