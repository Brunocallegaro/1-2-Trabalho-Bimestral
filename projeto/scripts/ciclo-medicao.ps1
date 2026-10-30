<#
  Ciclo de medicao do RotaExpress (Guia, passos 6.4, 7.1 a 7.4) em um unico comando.

  Faz exatamente o que o guia manda, na mesma ordem, e guarda tudo em resultados/:
    1. (opcional) kubectl scale + rollout status + endpointslices   -> NOME_escala.txt
    2. contadores dos Pods ANTES (logs --prefix --tail=1)          -> NOME_contadores_antes.txt
    3. kubectl apply -f k8s/job-carga.yaml
    4. kubectl wait ... pod -l job-name=carga                      (repete se o Pod ainda nao existe)
    5. kubectl logs -f job/carga  (mostra na tela)
       + kubectl top pods a cada 15 s em paralelo                   -> NOME_top.txt
    6. kubectl logs job/carga                                       -> NOME.txt   (evidencia principal)
    7. status do Job e codigo de saida do k6                        -> NOME_job.txt
    8. contadores dos Pods DEPOIS                                  -> NOME_contadores_depois.txt
    9. kubectl delete job carga

  Uso (PowerShell, dentro da pasta do projeto):
    .\scripts\ciclo-medicao.ps1 -Nome piloto
    .\scripts\ciclo-medicao.ps1 -Nome 3pods-a -Replicas 3

  Se o PowerShell bloquear scripts, rode uma vez nesta janela:
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#>
param(
    [Parameter(Mandatory = $true)][string]$Nome,
    [int]$Replicas = 0
)

# 'Continue' de proposito: no Windows PowerShell 5.1, stderr de programas externos
# com 2>&1 vira erro fatal se a preferencia for 'Stop'. Os erros reais usam throw.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz
$dir = Join-Path $raiz 'resultados'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

function Salvar([string]$arquivo, $conteudo) {
    $caminho = Join-Path $dir $arquivo
    ($conteudo | Out-String) | Out-File -FilePath $caminho -Encoding utf8
    Write-Host "  salvo: resultados\$arquivo"
}

function Kube {
    # Executa kubectl e devolve stdout+stderr como texto, sem interromper o script.
    $saida = & kubectl @args 2>&1 | ForEach-Object { "$_" }
    return ($saida -join [Environment]::NewLine)
}

if (Test-Path (Join-Path $dir "$Nome.txt")) {
    throw "resultados\$Nome.txt ja existe. Use outro nome (ex.: $Nome-r2) para nao sobrescrever evidencia."
}

Write-Host "== Contexto atual: $(Kube config current-context)"
$ns = Kube config view --minify --output 'jsonpath={..namespace}'
Write-Host "== Namespace padrao: $ns"
if ($ns -ne 'ops-lab') { throw "O namespace padrao nao e ops-lab. Rode: kubectl config set-context --current --namespace=ops-lab" }

$jobExistente = Kube get job carga --ignore-not-found -o name
if ($jobExistente) { throw "Ja existe um Job 'carga'. Salve os logs dele e rode: kubectl delete job carga" }

# 1. Escala (passo 7.1)
if ($Replicas -gt 0) {
    Write-Host "== Escalando para $Replicas replica(s)"
    $t = @()
    $t += Kube scale deployment/rotas --replicas=$Replicas
    & kubectl rollout status deployment/rotas --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw 'rollout status falhou; a medicao nao deve comecar sem convergencia.' }
    $t += Kube get pods -o wide
    $t += Kube get endpointslices -l kubernetes.io/service-name=rotas
    Salvar "$($Nome)_escala.txt" $t
}
Write-Host (Kube get deployment rotas)

# 2. Contadores antes (passo 7.2)
Write-Host '== Contadores ANTES'
$antes = Kube logs -l app=rotas --prefix --tail=1
Write-Host $antes
Salvar "$($Nome)_contadores_antes.txt" $antes

# 3. Cria o Job
Write-Host '== kubectl apply -f k8s/job-carga.yaml'
& kubectl apply -f k8s/job-carga.yaml
if ($LASTEXITCODE -ne 0) { throw 'apply do Job falhou (o ConfigMap carga-script existe?).' }

# 4. Espera o Pod do k6 ficar pronto
Write-Host '== Aguardando o Pod do k6 (na primeira vez a imagem e baixada)'
for ($i = 0; $i -lt 30; $i++) {
    $pod = Kube get pods -l job-name=carga -o name
    if ($pod) { break }
    Start-Sleep -Seconds 2
}
& kubectl wait --for=condition=Ready pod -l job-name=carga --timeout=180s
# Se o k6 terminar muito rapido o wait pode falhar; os logs ainda sao lidos abaixo.

# 5. Acompanha os logs e coleta kubectl top em paralelo (passo 7.3)
$coletor = Start-Job -ScriptBlock {
    for ($k = 1; $k -le 7; $k++) {
        Start-Sleep -Seconds 15
        "--- leitura $k ($(Get-Date -Format 'HH:mm:ss'))"
        & kubectl top pods 2>&1 | ForEach-Object { "$_" }
    }
}
& kubectl logs -f job/carga

# 6. Evidencia principal
Start-Sleep -Seconds 2
$log = Kube logs job/carga
Salvar "$Nome.txt" $log

# 7. Status do Job e codigo de saida do k6
Start-Sleep -Seconds 3
$jobInfo = @()
$jobInfo += Kube get job carga
$jobInfo += 'condicoes=' + (Kube get job carga -o 'jsonpath={.status.conditions[*].type}')
$jobInfo += 'exit_code_k6=' + (Kube get pods -l job-name=carga -o 'jsonpath={.items[0].status.containerStatuses[0].state.terminated.exitCode}')
Salvar "$($Nome)_job.txt" $jobInfo
Write-Host ($jobInfo -join [Environment]::NewLine)

Stop-Job $coletor -ErrorAction SilentlyContinue
$top = Receive-Job $coletor -ErrorAction SilentlyContinue
Remove-Job $coletor -Force -ErrorAction SilentlyContinue
Salvar "$($Nome)_top.txt" $top

# 8. Contadores depois (passo 7.4)
Write-Host '== Contadores DEPOIS'
$depois = Kube logs -l app=rotas --prefix --tail=1
Write-Host $depois
Salvar "$($Nome)_contadores_depois.txt" $depois

# 9. Limpa o Job para o proximo teste
& kubectl delete job carga
Write-Host "== Fim da medicao '$Nome'. Proximo passo: .\scripts\extrair-resultados.ps1"
