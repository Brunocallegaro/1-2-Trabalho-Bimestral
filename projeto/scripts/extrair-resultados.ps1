<#
  Le os registros salvos em resultados/ e preenche a tabela de medicoes.

  Entrada : resultados_modelo.csv (ordem e rotulos das medicoes)
            resultados/NOME.txt                 (log do k6, obrigatorio)
            resultados/NOME_job.txt             (status do Job, opcional)
            resultados/NOME_top.txt             (kubectl top, opcional)
            resultados/NOME_contadores_*.txt    (contadores dos Pods, opcional)
  Saida   : resultados.csv          mesmas colunas do modelo, uma linha por medicao
            resultados/medianas.csv mediana por quantidade de Pods (Guia, passo 8.3)

  Nada e inventado: medicao sem arquivo fica em branco com "PENDENTE" em observacoes.
  Numeros usam virgula decimal e ';' como separador (Excel em portugues).

  Uso: .\scripts\extrair-resultados.ps1
#>
param(
    [string]$Modelo = 'resultados_modelo.csv',
    [string]$Saida = 'resultados.csv'
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz
$dir = Join-Path $raiz 'resultados'
$ci = [System.Globalization.CultureInfo]::InvariantCulture

function Ler([string]$arquivo) {
    $p = Join-Path $dir $arquivo
    if (Test-Path $p) { return (Get-Content -Path $p -Raw) }
    return $null
}

function Num([string]$texto) { return [double]::Parse($texto, $ci) }

function Br($valor, [int]$casas = 2) {
    if ($null -eq $valor) { return '' }
    return ([math]::Round([double]$valor, $casas)).ToString($ci).Replace('.', ',')
}

function EmMs([string]$valor, [string]$unidade) {
    $v = Num $valor
    switch ($unidade) {
        's'  { return $v * 1000 }
        'ms' { return $v }
        default { return $v / 1000 }   # microssegundos
    }
}

function Mediana($valores) {
    $v = @($valores | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $m = [math]::Floor($v.Count / 2)
    if ($v.Count % 2 -eq 1) { return $v[$m] }
    return ($v[$m - 1] + $v[$m]) / 2
}

function Contadores([string]$texto) {
    # [pod/rotas-abc-xyz/rotas] aceito calculo_ms=441.2 total_aceitos=118 total_recusados=41
    $mapa = @{}
    if (-not $texto) { return $mapa }
    foreach ($linha in ($texto -split "`r?`n")) {
        if ($linha -match '^\[pod/([^/\]]+)/[^\]]*\]\s*(.*)$') {
            $pod = $Matches[1]; $resto = $Matches[2]
            $a = 0; $r = 0
            if ($resto -match 'total_aceitos=(\d+)') { $a = [int]$Matches[1] }
            if ($resto -match 'total_recusados=(\d+)') { $r = [int]$Matches[1] }
            $mapa[$pod] = @($a, $r)
        }
    }
    return $mapa
}

function Curto([string]$pod) {
    $partes = $pod -split '-'
    return $partes[$partes.Count - 1]
}

$linhas = Import-Csv -Path $Modelo -Delimiter ';'
$colunas = (Get-Content -Path $Modelo -TotalCount 1).Split(';')
$saidaLinhas = @()
$porReplica = @{}

foreach ($l in $linhas) {
    $nome = $l.rotulo
    $log = Ler "$nome.txt"
    if (-not $log) {
        $l.observacoes = "PENDENTE: resultados/$nome.txt nao encontrado"
        $saidaLinhas += $l
        continue
    }
    $obs = @()

    if ($log -match 'medicao:\s*([\d.]+)\s*iterations/s') { $l.taxa = Br (Num $Matches[1]) 0 }

    $rotasOk = $null
    if ($log -match 'rotas_ok\.+:\s*(\d+)') { $rotasOk = [int]$Matches[1] }
    elseif ($log -match 'falhas\.+:') { $rotasOk = 0 }    # nenhuma rota valida: o k6 nao imprime a linha
    if ($null -ne $rotasOk) {
        $l.rotas_ok = $rotasOk
        $l.sucessos_por_s = Br ($rotasOk / 60) 2
    }

    $falhas = $null
    if ($log -match 'falhas\.+:\s*([\d.]+)%\s+(\d+)\s+out of\s+(\d+)') {
        $falhas = Num $Matches[1]
        $l.falhas_pct = Br $falhas 2
        $obs += "tentativas=$($Matches[3])"
    }

    $p95 = $null; $media = $null
    if ($log -match 'latencia_ok\.+:\s*avg=([\d.]+)([^\d\s.]+)\s+med=[\d.]+[^\d\s.]+\s+p\(95\)=([\d.]+)([^\d\s.]+)') {
        $media = EmMs $Matches[1] $Matches[2]
        $p95 = EmMs $Matches[3] $Matches[4]
        $l.p95_latencia_ok_ms = Br $p95 1
        $obs += "media_ok_ms=$(Br $media 1)"
    }

    $drop = $null
    if ($log -match "dropped_iterations\{scenario:medicao\}\s*[\r\n]+\s*\S+\s*'count==0'\s*count=(\d+)") { $drop = [int]$Matches[1] }
    elseif ($log -match '\{\s*scenario:medicao\s*\}\.+:\s*(\d+)') { $drop = [int]$Matches[1] }
    if ($null -ne $drop) { $l.dropped_iterations_medicao = $drop }

    if ($log -notmatch 'THRESHOLDS') { $obs += 'ATENCAO: log sem resumo do k6 (nao e medicao valida)' }

    $job = Ler "$($nome)_job.txt"
    if ($job) {
        if ($job -match 'condicoes=.*Failed') { $l.status_job = 'Failed' }
        elseif ($job -match 'condicoes=.*Complete') { $l.status_job = 'Complete' }
        if ($job -match 'exit_code_k6=(\d+)') { $obs += "exit_k6=$($Matches[1])" }
    }

    $antes = Contadores (Ler "$($nome)_contadores_antes.txt")
    $depois = Contadores (Ler "$($nome)_contadores_depois.txt")

    $top = Ler "$($nome)_top.txt"
    if ($top) {
        $cpu = @{}; $mem = 0
        foreach ($linha in ($top -split "`r?`n")) {
            if ($linha -match '^(rotas-\S+)\s+(\d+)m\s+(\d+)Mi') {
                $pod = $Matches[1]; $c = [int]$Matches[2]; $m = [int]$Matches[3]
                # Ignora Pods que ja estavam sendo encerrados depois de um scale para menos
                # (aparecem no top, mas nao estao nos contadores do fim do teste).
                if ($depois.Count -gt 0 -and -not $depois.ContainsKey($pod)) { continue }
                if (-not $cpu.ContainsKey($pod) -or $cpu[$pod] -lt $c) { $cpu[$pod] = $c }
                if ($m -gt $mem) { $mem = $m }
            }
        }
        if ($cpu.Count -gt 0) {
            $l.cpu_observada_por_pod = 'max ' + (($cpu.Keys | Sort-Object | ForEach-Object { "$(Curto $_)=$($cpu[$_])m" }) -join ' ')
            $obs += "mem_max_mi=$mem"
        }
    }
    if ($depois.Count -gt 0) {
        $partes = foreach ($pod in ($depois.Keys | Sort-Object)) {
            $a0 = 0; $r0 = 0
            if ($antes.ContainsKey($pod)) { $a0 = $antes[$pod][0]; $r0 = $antes[$pod][1] }
            "$(Curto $pod)=+$($depois[$pod][0] - $a0)/-$($depois[$pod][1] - $r0)"
        }
        $l.distribuicao_aceitos_por_pod = ($partes -join ' ')
    }

    # ' | ' e nao ';' para nao quebrar a coluna no CSV separado por ';'
    $l.observacoes = ($obs -join ' | ')
    $saidaLinhas += $l

    if ($l.rodada -ne 'calibracao' -and $null -ne $rotasOk) {
        $rep = [int]$l.replicas
        if (-not $porReplica.ContainsKey($rep)) { $porReplica[$rep] = @() }
        $porReplica[$rep] += [pscustomobject]@{ suc = $rotasOk / 60; fal = $falhas; p95 = $p95; med = $media; drop = $drop; nome = $nome }
    }
}

# Tabela completa
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$texto = ($saidaLinhas | ConvertTo-Csv -Delimiter ';' -NoTypeInformation | ForEach-Object { $_ -replace '"', '' }) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $raiz $Saida), $texto + "`r`n", $utf8Bom)
Write-Host "Tabela gravada em $Saida"

# Medianas por configuracao (Guia, passo 8.3)
$med = @('replicas;medicoes_usadas;mediana_sucessos_por_s;mediana_falhas_pct;mediana_p95_latencia_ok_ms;mediana_latencia_media_ok_ms;max_dropped_iterations')
foreach ($rep in ($porReplica.Keys | Sort-Object)) {
    $g = $porReplica[$rep]
    $med += '{0};{1};{2};{3};{4};{5};{6}' -f $rep, (($g | ForEach-Object nome) -join ' '),
        (Br (Mediana ($g | ForEach-Object suc)) 2), (Br (Mediana ($g | ForEach-Object fal)) 2),
        (Br (Mediana ($g | ForEach-Object p95)) 1), (Br (Mediana ($g | ForEach-Object med)) 1),
        (($g | ForEach-Object drop | Measure-Object -Maximum).Maximum)
}
[System.IO.File]::WriteAllText((Join-Path $dir 'medianas.csv'), ($med -join "`r`n") + "`r`n", $utf8Bom)
Write-Host 'Medianas gravadas em resultados\medianas.csv'
Get-Content (Join-Path $dir 'medianas.csv')
