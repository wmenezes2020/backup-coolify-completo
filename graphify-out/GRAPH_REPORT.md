# Graph Report - BACKUP COOLIFY  (2026-10-05)

## Corpus Check
- Corpus is ~24,784 words - fits in a single context window. You may not need a graph.

## Summary
- 132 nodes · 288 edges · 13 communities
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- backup-coolify.sh
- restaurar-coolify.sh script
- backup-coolify.sh script
- restaurar-coolify.sh
- testa-auth.sh
- configura_drive
- dump_postgres
- autoriza_por_link
- gerar-grafo.py
- restaura_volume
- apaga_token_api
- instala_coolify
- diz

## God Nodes (most connected - your core abstractions)
1. `backup-coolify.sh script` - 30 edges
2. `restaurar-coolify.sh script` - 29 edges
3. `configura_drive()` - 15 edges
4. `autoriza_por_link()` - 12 edges
5. `envia_para_drive()` - 12 edges
6. `feito()` - 10 edges
7. `aviso()` - 10 edges
8. `instala_rclone()` - 10 edges
9. `falha()` - 9 edges
10. `dump_postgres()` - 9 edges

## Surprising Connections (you probably didn't know these)
- `backup-coolify.sh script` --calls--> `configura_drive()`  [EXTRACTED]
  backup-coolify.sh → backup-coolify.sh  _Bridges community 2 → community 5_
- `backup-coolify.sh script` --calls--> `diz()`  [EXTRACTED]
  backup-coolify.sh → backup-coolify.sh  _Bridges community 2 → community 12_
- `backup-coolify.sh script` --calls--> `dump_clickhouse()`  [EXTRACTED]
  backup-coolify.sh → backup-coolify.sh  _Bridges community 2 → community 6_
- `autoriza_por_link()` --calls--> `diz()`  [EXTRACTED]
  backup-coolify.sh → backup-coolify.sh  _Bridges community 12 → community 7_
- `configura_drive()` --calls--> `diz()`  [EXTRACTED]
  backup-coolify.sh → backup-coolify.sh  _Bridges community 12 → community 5_

## Import Cycles
- None detected.

## Communities (13 total, 0 thin omitted)

### Community 0 - "backup-coolify.sh"
Cohesion: 0.11
Nodes (11): AVISOS, BANCO_ENGINE, BANCO_ID, BANCO_NOME, BINDS, BINDS_BRUTOS, CONTAINERS_PARADOS, ERROS (+3 more)

### Community 1 - "restaurar-coolify.sh script"
Cohesion: 0.12
Nodes (17): ajuda(), api_responde(), banco_pg(), conta(), espera_banco(), espera_painel(), estava_de_pe_na_origem(), exige_palavra() (+9 more)

### Community 2 - "backup-coolify.sh script"
Cohesion: 0.17
Nodes (16): ajuda(), aviso(), conta(), copia_se_tem(), copia_volume(), detecta_engine(), espaco_livre(), ignora_bind() (+8 more)

### Community 3 - "restaurar-coolify.sh"
Cohesion: 0.13
Nodes (11): atualiza_pg(), AVISOS, DEPLOY_FEITO, DEPLOY_PULADO, DEPLOY_RECUSADO, dispara_recurso(), ERROS, FLAGS_EXTRACAO (+3 more)

### Community 4 - "testa-auth.sh"
Cohesion: 0.24
Nodes (8): caso(), nao_tem_texto(), nok(), ok(), prepara(), roda_auth(), testa-auth.sh script, tem_texto()

### Community 5 - "configura_drive"
Cohesion: 0.38
Nodes (11): arquivo_conf_rclone(), configura_drive(), envia_para_drive(), escreve_remote_rclone(), falha(), feito(), instala_rclone(), passo() (+3 more)

### Community 6 - "dump_postgres"
Cohesion: 0.49
Nodes (10): b64(), confere_dump(), dump_clickhouse(), dump_mongo(), dump_mysql(), dump_postgres(), env_do_container(), registra_banco() (+2 more)

### Community 7 - "autoriza_por_link"
Cohesion: 0.25
Nodes (9): autoriza_por_chave_propria(), autoriza_por_link(), escopo_codificado(), le_do_tty(), mostra_passos_da_chave(), numero_json(), pergunta_sim(), tem_terminal() (+1 more)

### Community 8 - "gerar-grafo.py"
Cohesion: 0.33
Nodes (6): json, pathlib, dentro_do_escopo(), main(), Gera o grafo do graphify deste repositorio em graphify-out/. Entrega sempre os…, sys

### Community 9 - "restaura_volume"
Cohesion: 0.40
Nodes (5): aviso(), escolhe_temp(), falha(), meta_do_volume(), restaura_volume()

### Community 10 - "apaga_token_api"
Cohesion: 0.50
Nodes (4): apaga_token_api(), cria_token_api(), na_saida(), psql_painel()

### Community 11 - "instala_coolify"
Cohesion: 0.50
Nodes (4): define_compose(), diz(), instala_coolify(), tem()

### Community 12 - "diz"
Cohesion: 1.00
Nodes (3): diz(), na_saida(), religa_containers()

## Knowledge Gaps
- **20 isolated node(s):** `CONTAINERS_PARADOS`, `AVISOS`, `ERROS`, `FLAGS_TAR`, `VOLUMES_PRONTOS` (+15 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 37 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `restaurar-coolify.sh script` connect `restaurar-coolify.sh script` to `instala_coolify`, `restaura_volume`, `apaga_token_api`, `restaurar-coolify.sh`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Why does `backup-coolify.sh script` connect `backup-coolify.sh script` to `backup-coolify.sh`, `diz`, `configura_drive`, `dump_postgres`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **What connects `CONTAINERS_PARADOS`, `AVISOS`, `ERROS` to the rest of the system?**
  _20 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `backup-coolify.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.1111111111111111 - nodes in this community are weakly interconnected._
- **Should `restaurar-coolify.sh script` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Should `restaurar-coolify.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._