# resultados/

Pasta das evidências das medições no cluster. **Está vazia de propósito**: nenhuma
medição em Kubernetes foi feita na preparação do projeto (ver `../validacao_local/LEIAME.md`).

Cada execução de `.\scripts\ciclo-medicao.ps1 -Nome NOME` grava aqui:

| Arquivo | Conteúdo |
|---|---|
| `NOME.txt` | Log completo do k6 (`kubectl logs job/carga`). **Evidência principal.** |
| `NOME_job.txt` | `kubectl get job carga`, condições do Job e código de saída do k6. |
| `NOME_top.txt` | Leituras de `kubectl top pods` a cada 15 s durante o teste. |
| `NOME_contadores_antes.txt` / `_depois.txt` | `kubectl logs -l app=rotas --prefix --tail=1` antes e depois. |
| `NOME_escala.txt` | Saída do `scale`, Pods e EndpointSlices (quando usou `-Replicas`). |

Nomes esperados, na ordem do guia (passo 7.5):
`piloto`, `3pods-a`, `1pod-a`, `2pods-a`, `2pods-b`, `3pods-b`, `1pod-b`, `1pod-c`, `2pods-c`, `3pods-c`.

Depois de todas, rode `.\scripts\extrair-resultados.ps1`: ele gera `../resultados.csv`
e `medianas.csv` a partir destes arquivos. Teste interrompido não vira zero: renomeie os
arquivos dele (ex.: `2pods-b.txt` → `2pods-b_interrompido.txt`), anote o motivo em
`observacoes` e rode de novo com o mesmo nome.
