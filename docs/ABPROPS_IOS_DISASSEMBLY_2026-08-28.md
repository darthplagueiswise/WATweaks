# WhatsApp iOS ABProps: pesquisa, disassembly e técnica de full fetch

Artefatos analisados diretamente:

- `SharedModules(5)` — SHA-256 `f0edef076c68d7f1f872401d774789a2cb3f50be5c96773a2d8ed763ed3015a7`
- `WhatsApp(5)` — SHA-256 `9f08516fa766f3697a54804207721d5bf14fbc5a22d6930236e43510e44ee7af`

A leitura foi feita nos Mach-O arm64 fornecidos, incluindo metadata Objective-C
relativa, categories e `LC_DYLD_CHAINED_FIXUPS`, e o código foi decodificado com
LIEF/Capstone. Os endereços abaixo pertencem somente a esses hashes.

## 1. O que os projetos públicos realmente fazem

| Projeto | Evidência | Conclusão útil para iOS |
|---|---|---|
| [darthplagueiswise/ABProps](https://github.com/darthplagueiswise/ABProps/blob/35393ca7e965f4bfcbcbb6412975dfa3454436c8/ABProps/WebABProps.swift) | Abre `web.whatsapp.com` em `WKWebView` desktop, baixa bundles JS e extrai `ABPropConfigs`. | Obtém um catálogo Web público `code → name/type`. Não usa a sessão XMPP do WhatsApp iOS e não baixa as atribuições ABT da conta. É uma fonte de nomes Web, não o transporte nativo iOS. |
| [Cobalt no commit indicado](https://github.com/Auties00/Cobalt/blob/cb9fbf172507626948fbc3611d0a6fb00bb3a0f1/modules/lib/src/main/java/com/github/auties00/cobalt/props/LiveABPropsService.java#L328-L480) | Envia `<iq xmlns="abt" to="s.whatsapp.net" type="get"><props protocol="1" .../></iq>`. Full omite os dois validators; regular envia `hash`; emergência envia `refresh_id`. | Especifica o protocolo e confirma que `hash` e `refresh_id` são ramos, não campos a combinar. Usa a própria sessão conectada do Cobalt. |
| [oxidezap/whatsapp-rust](https://github.com/oxidezap/whatsapp-rust/blob/94d6c95c918becf1742762a928dc97be0abc0fcc/wacore/src/iq/props.rs) | `PropsSpec::new()` não envia `hash` nem `refresh_id`; os construtores com hash/refresh são mutuamente exclusivos e têm testes do IQ. | Confirma de forma independente o wire format, o parser de `config_code/config_value` e a semântica full/regular/emergência. |

Não foi encontrada implementação pública que use os nomes privados exatos do
iOS (`XMPPConnectionABPropsRequestManager`, `WAABPropsRequestBuilder`,
`XMPPRequestABProperties`) ou as chaves `gabp.o…p/c`. Portanto o Mach-O desta
build, e não um port Android/Web, é a fonte de verdade para o vínculo de objetos.

## 2. Pipeline ABT ativo em `SharedModules(5)`

| Classe / selector | IMP | Classificação | Evidência de fluxo |
|---|---:|---|---|
| `-[XMPPConnectionABPropsRequestManager requestFreshABProps:withCompletion:]` | `0x003f55f8` | thunk ativo | Reorganiza argumentos, força `groupJID=nil` e chama o método inferior. O `BOOL` é `deltaUpdate`. |
| `-requestFreshABPropsWithGroupJID:deltaUpdate:completion:` | `0x003e5bf8` | ativo | Usa o retry manager nativo e chama `performABPropsAttempt…`. |
| `-[XMPPConnection(RequestABProps) queryABPropertiesWithGroupJID:deltaUpdate:completion:]` | `0x003f57b0` | ativo | Cria `WAABPropsRequestBuilder`, constrói o request e chama `enqueueRequest:` na conexão autenticada existente. |
| `-[WAABPropsRequestBuilder buildXMPPRequestABPropertiesWithGroupJID:deltaUpdate:completion:]` | `0x003f5820` | ativo | Para `NO`, lê `abProperties.configHash` e passa `refreshID=nil`; para `YES`, passa `configHash=nil` e usa `refreshID` (ou `@"0"`). |
| `-[XMPPRequestABProperties initWithUserContext:groupJID:configHash:refreshID:completion:]` | `0x003f58ec` | ativo | Omite individualmente os atributos cujo argumento é `nil`; não é stub. |
| `-[XMPPConnectionABPropsRequestManager handleABPropsResponseForGroupJID:…]` | `0x003fee38` | ativo | Classifica erro/retry; resposta full chama `updateWithProperties…` em `0x003ff0d0`; delta chama `deltaUpdateWithNewProperties…` em `0x003ff0e0`. |
| `-[WAProperties updateWithProperties:…]` | `0x00430a64` | ativo | Encaminha o full replace ao `WAPropertiesStore`. |
| `-[WAProperties deltaUpdateWithNewProperties:refreshID:]` | `0x00699e30` | thunk ativo | Encaminha merge delta ao `WAPropertiesStore`. |
| `-[WAProperties resetConfigHashToEmptyString]` | `0x021db9a8` | thunk ativo | Carrega o `WAPropertiesStore` do objeto e chama o mesmo selector. |
| `-[WAPropertiesStore resetConfigHashToEmptyString]` | `0x0214f72c` | ativo | Executa a mutação/persistência nativa do hash. |

Consequência: o transporte ABT não precisa ser “religado”. Ele já funciona. O
problema do fetch explícito era chamar o ramo regular com o hash atual, permitindo
uma resposta válida de `no-change`, e depois tentar inferir rede somente por uma
mudança de fingerprint.

## 3. Técnica adotada: reset nativo + request regular

`WAGRABPropsABTLiveFetchForcedFull` agora executa uma transação sem hook global:

1. resolve apenas o `XMPPConnectionABPropsRequestManager` pertencente à conexão
   XMPP viva da `WAContext` atual e valida o ABI `v28@0:8B16@?20`;
2. resolve exatamente `userContext.abProperties`, que é o mesmo objeto lido pelo
   builder no caminho `groupJID=nil`;
3. lê o hash anterior e chama o par ativo
   `WAProperties.resetConfigHashToEmptyString`;
4. exige readback de string vazia antes de enviar; `nil` não é aceito como se
   fosse a variante de hash vazio;
5. chama `requestFreshABProps:NO`, fazendo o builder oficial enviar hash vazio e
   `refreshID=nil` pela conexão autenticada;
6. aguarda o completion do retry pipeline nativo;
7. só marca `verified_native_completion_hash_refilled` quando o `configHash` daquele mesmo
   objeto account-scoped volta a ser não vazio.

O uso de hash vazio como cache miss é uma inferência sustentada por três fatos:
o método nativo tem esse nome explícito, o builder envia seu resultado no ramo
regular, e o protocolo público devolve full quando o validator não corresponde.
O WATweaks não transforma a inferência em falso sucesso: se o servidor/build não
repor o hash, o resultado permanece não confirmado.

Esse botão hook-free registra `wire_response_observed=false`: ele verifica o
completion e o pós-estado do objeto exato, mas não afirma observação direta do
handler. A prova wire/handler/store é responsabilidade do Runtime Lab abaixo.

Uma mudança de `gabp.*p` é registrada como evidência secundária. Ela não é
obrigatória, pois um full fetch pode substituir o store pelo mesmo conjunto de
props e produzir fingerprint idêntico.

Foram removidos do caminho de produção:

- o hook de initializer instalado automaticamente no launch;
- a condição global “armada” que podia interceptar uma requisição concorrente;
- o polling de fingerprint tratado como resultado de rede;
- três translation units que substituíam o mesmo botão em `+0…7,5 s` e tornavam
  o comportamento dependente da ordem de constructors.

Os observers antigos de handler continuam disponíveis para diagnóstico explícito,
mas não são mais instalados automaticamente no cold start.

## 3.1 ABT Runtime Lab

O menu `AB Props → ABT Runtime Lab` executa, na mesma build, a matriz completa
que o protocolo e esta disassembly sustentam:

| Variante | `deltaUpdate` | `configHash` efetivo | `refreshID` efetivo | Técnica |
|---|---:|---|---|---|
| `regular_hash` | `NO` | valor atual | `nil` | Caminho nativo sem mutação. |
| `delta_refresh_id` | `YES` | `nil` | valor atual ou fallback nativo `"0"` | Caminho nativo sem mutação. |
| `full_no_validators` | `NO` | `nil` | `nil` | Override de argumentos limitado à transação no initializer ativo; manager, conexão, parser, retries, handler e store permanecem nativos. |
| `full_empty_hash` | `NO` | string vazia | `nil` | `WAProperties.resetConfigHashToEmptyString` seguido do caminho nativo regular. |

Além da matriz canônica, a seção **Wire custom em runtime** permite escolher
`deltaUpdate`, e aplicar independentemente a `configHash` e `refreshID` uma das
políticas `native`, `nil`, `empty`, `zero` ou `custom` (string de até 256 caracteres),
com timeout entre 45 e 120 segundos. O mínimo preserva a janela de retries nativa
de 2/4 tentativas observada nesta build. Isso cobre também combinações deliberadamente
não canônicas sem nova compilação; elas nunca entram na matriz padrão e um erro
do servidor permanece um resultado de erro.

Os hooks de correlação só são instalados quando o usuário inicia um teste. Fora
de uma transação eles apenas encaminham para os IMPs originais. A substituição de
validators é armada exclusivamente para `full_no_validators`, exige o mesmo
`userContext`, `groupJID=nil`, o shape esperado do builder e é reaplicada aos
requests de retry pertencentes à janela correlacionada.

Cada tentativa criada pelo manager é identificada pelo objeto exato
`XMPPRequestABProperties`; `didSucceedWithResponse:` e `didFailWithError:` só são
atribuídos ao teste quando `self` está nesse conjunto. O handler só é aceito
quando executa de forma aninhada no callback desse request exato, na mesma thread
e para o manager da transação. Um evento anterior não basta. Isso preserva falhas
intermediárias, rejeita tráfego ABT concorrente e permite que um retry posterior
seja corretamente classificado como sucesso.

Completion e timeout também carregam o token da transação. O timeout publica um
resultado terminal, desmonta somente a correlação do WATweaks e libera o gate.
Um completion nativo tardio continua sendo encaminhado ao WhatsApp, mas não pode
alterar o resultado publicado nem adquirir novamente o gate. A matriz é
interrompida no timeout para conservar o relatório daquela variante.

Como o completion pode ocorrer dentro do handler, a finalização espera o handler
correlacionado terminar de registrar o payload antes de reler o store. A matriz
mantém ainda um gate ABT como owner durante as quatro variantes; cada request é
um child token. Assim nenhum dos outros botões de full fetch consegue entrar nem
mesmo no intervalo entre duas variantes.

Um resultado recebe `verified_native_response_applied` apenas quando todos estes
fatos coincidem:

1. o método inferior exato foi alcançado;
2. o initializer registrou os validators efetivos;
3. o request correlacionado executou `didSucceedWithResponse:`;
4. o handler exato foi observado sem erro;
5. o completion do retry pipeline foi chamado;
6. o cache account-scoped foi relido e os metadados devolvidos conferem com o
   `WAPropertiesStore`;
7. o shape efetivo do wire corresponde à variante em todas as tentativas;
8. nas variantes full, o handler entrega resposta não-delta com props; na variante
   de hash vazio, o hash account-scoped também precisa ter sido reposto.

No branch delta, a confirmação respeita o contrato efetivamente disassemblado:
`deltaUpdateWithNewProperties:refreshID:` persiste o merge e o `refreshID`, mas
não recebe `encryptedRID`. O relatório preserva a comparação bruta em
`encrypted_rid_matches` e registra `encrypted_rid_persistence_expected=false`;
uma rotação do RID presente apenas na resposta delta não é tratada como falha do
store. No branch full, a correspondência do RID continua obrigatória.

O Lab oferece execução individual, bateria sequencial das quatro variantes,
timeout de 45 segundos por variante canônica (45–120 segundos no wire custom),
histórico compacto persistente, log de sessão e exportação
`watweaks_abt_runtime_lab.json`. O relatório inclui o estado do gate, a eventual
quarentena e o outcome da matriz. Seu escopo é explicitamente somente ABT;
MobileConfig não é inferido dele.

## 4. O que é realmente `no-op`: bridge ABProps → MobileConfig

No executável principal:

| Classe / selector | IMP | Resultado nesta build |
|---|---:|---|
| `+[WAMobileConfigABPropsOverridesSync syncABPropsOverridesToMCWithUserContext:]` | `0x1002074ac` | Tail-call para `0x10003d8f8`, que é `mov x0,#0; ret`. Stub desativado. |
| `+overriddenStableIdsWithUserContext:` | `0x10003a3a4` | Retorna `___NSArray0__struct`, ou seja, array vazio. |
| `-[WADebugViewController resetAllOverriddenABProps]` | `0x10004f188` | `ret`. |

Esse scaffold não é o transporte ABT. Os pares ativos abaixo delimitam a pesquisa
MobileConfig, mas a validação e a entrega dessa solução pertencem ao checkpoint
seguinte; o artefato ABT não usa esses stubs para buscar props:

| Componente ativo | Selector / IMP relevante | Papel |
|---|---|---|
| `WAMCEvaluation` | `getMCSpecifierForStableId:` | Traduz AB stable ID para `paramSpecifier`. |
| `FBMobileConfigStartupConfigs` | `+getInstance` `0x020ac374` | Obtém o writer nativo de overrides de startup. |
| `FBMobileConfigStartupConfigs` | `setOverrideForParam:andValue:` `0x010357f8` | Aplica valor tipado pelo specifier real. |
| `FBMobileConfigStartupConfigs` | `removeOverrideForParam:` `0x00b2b00c` | Remove o override. |
| `FBMobileConfigContextManager` | `invalidateCachedLatestContext` `0x003ffe84` | Invalida o contexto avaliado. |
| `FBMobileConfigContextManager` | `forceRefreshOfConfig:` `0x018d1bf8` | Solicita refresh direcionado do config externo. |

`setOverrides:` não é chamado com `objc_msgSend`: nessa build seu ABI carrega
`std::shared_ptr<FBMobileConfigOverridesTable>`, portanto tratá-lo como `id` seria
incorreto.

O editor ABProps usa, neste checkpoint, somente o writer em memória
`FBMobileConfigStartupConfigs` e em seguida invalida/atualiza o contexto. Ele
mantém um registro de intenção do WATweaks para reaplicação, mas não afirma nem
simula persistência no `mc_overrides.json`. O caminho físico continua desligado
até que o serializer principal e o diretório exato da UserSession sejam
comprovados no framework e nos arquivos reais do container. O fallback chamado
`RUNTIME` permanece um swizzle local explicitamente identificado na interface.

## 5. `id_name_mapping.json` e `mc_overrides.json` não são ABT

As strings existem em `SharedModules`, mas pertencem ao resource/schema plumbing
de MobileConfig. O cache ABT observado está no domínio
`group.net.whatsapp.WhatsApp.shared`:

- `gabp.o<account>p`: dicionário account-scoped de props (5.872 entradas no
  plist fornecido);
- `gabp.o<account>c`: `key`, `hash`, `refreshInterval`, `refreshID`,
  `encryptedRID`;
- `gabp.o<account>s`: sampling weights;
- `gabp.o<account>m`: versão/data/metadados de refresh.

O `id_name_mapping.json` pode enriquecer nomes de config/parâmetro MobileConfig,
mas não é necessário para baixar os valores ABT. A aquisição/geração desse arquivo
e a escrita/leitura validada de `mc_overrides.json` ficam explicitamente fora
deste checkpoint ABT. Para nomes nativos iOS, o
WATweaks continua priorizando a relação `getter IMP → descriptor → decimal code`
extraída da própria build; o catálogo Web é, no máximo, uma fonte adicional que
deve permanecer identificada como Web.

## 6. Limites da verificação

- O disassembly e os checks estáticos estão concluídos para os dois hashes acima.
- Build/CI prova compatibilidade de compilação, não resposta do servidor.
- O único teste final de rede é executar uma variante ou a matriz numa conta
  conectada e obter no JSON `wire_response_observed=true`,
  `native_completion_observed=true`, `store_confirmation.metadata_matches=true`
  e `outcome=verified_native_response_applied`. O botão de produção sem hooks
  conserva também o critério `config_hash_refilled=true`.
- Nenhum resultado é rotulado como “download concluído” apenas porque o selector
  foi invocado.

## Checkpoint ABT Browser: store account-scoped sem heurística

A análise do metadata Objective-C do `SharedModules(5)` fecha o vínculo do
objeto usado na requisição até o store que alimenta o browser:

| Objeto | Campo/selector | Offset/IMP | Uso |
|---|---|---:|---|
| `WAProperties` | `_propertiesStore` / `propertiesStore` | `+0x8` / `0x0056ec` | Store pertencente ao mesmo `WAProperties` passado ao manager. |
| `WAPropertiesStore` | `preferencesStore` | `+0x8` | Backend nativo que persiste no App Group. |
| `WAPropertiesStore` | `namespace` | `+0x20` | Namespace nativo (`gabp.o` no fluxo pessoal observado). |
| `WAPropertiesStore` | `propertiesType` | `+0x30` | Escopo/tipo do store. |
| `WAPropertiesStore` | `groupJID` | `+0x38` | Escopo de grupo, quando existente. |
| `WAPropertiesStore` | `properties` | `+0x60` | Dicionário ABProps exato carregado/persistido pelo store. |

Os type encodings dos ivars locais de `WAPropertiesStore` estão vazios nesta
build, embora a ivar list preserve nome, offset, alinhamento e tamanho. Para
`propertiesType`, a leitura de oito bytes em `+0x30` é validada também pelo ABI
do initializer (`@68@0:8@16@24@32@40q48@56B64`); exigir um type encoding que o
próprio binário removeu fazia o reader rejeitar o store correto.

O reader de produção valida todos esses offsets em runtime e recusa o snapshot
se a build divergir. Ele não enumera `group.net.whatsapp.WhatsApp.shared`, não
seleciona o maior `gabp.*p` e não tenta inferir a conta pelo número de entries.
A enumeração antiga permanece somente como diagnóstico não atribuído.

O botão Fetch dos dois browsers usa apenas `full_empty_hash`. A UI só substitui
sua fonte depois que a mesma transação confirma:

1. `XMPPRequestABProperties` recebeu `didSucceedWithResponse:` com `XMPPIQStanza`;
2. o handler foi correlacionado e trouxe resposta full com `prop_count > 0`;
3. hash/refresh/encryptedRID do mesmo store correspondem à resposta e o hash foi reposto;
4. as contagens wire, store exato, documento e `entries` são idênticas.

O JSON do browser é ABT-only. MobileConfig fica deliberadamente fora deste
checkpoint até que o fetch e os arquivos reais do container sejam analisados.
O browser relê esse store exato em cada scan/pull-to-refresh e avalia os getters
Objective-C quando recria as linhas; não conserva o documento verificado como
snapshot congelado. Se fingerprint, identidade ou contagem mudarem depois de uma
transação verificada, a tela mostra o estado atual e remove apenas o selo de
proveniência da transação anterior.
