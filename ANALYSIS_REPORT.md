# WATweaks alpha native debug log guard

O log enviado confirma que o patch de datasource foi carregado: `WADebugViewController` e `DebugMenuProvider` foram hookados e o `didSelect` também entrou. Porém o trecho mostrado ainda é fase de instalação/retry; ele não mostra a tela consultando o datasource. O sinal funcional esperado ao abrir o Debug Menu é `numberOfSections native=5 final=6` e depois a seção `WATweaks`.

Este patch corrige apenas o ruído/retry:

- `WAGRDMInstall` agora retorna `NO` quando o hook já existe, evitando contadores falsos em chamadas repetidas.
- `assembly probes checked` foi trocado por log de instalação real, emitido só quando algo novo é hookado.
- `ensure installed` ficou estável: loga apenas quando `debugVC/provider/totalHooks` muda.

Não altera a lógica da seção WATweaks nem mexe em `WATableSection`/`WATableRow`.
