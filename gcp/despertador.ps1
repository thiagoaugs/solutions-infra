<#
.SYNOPSIS
  Atalho para acordar/hibernar um ambiente no GCP (Windows / PowerShell).

.EXAMPLE
  .\gcp\despertador.ps1 homologacao acordar      # liga a homologação para testar (2h, depois hiberna sozinha)
  .\gcp\despertador.ps1 homologacao acordar 4    # liga por 4 horas
  .\gcp\despertador.ps1 homologacao hibernar     # desliga agora
  .\gcp\despertador.ps1 producao acordar         # produção fora do horário (pede confirmação)
  .\gcp\despertador.ps1 producao status          # mostra o estado

  Requer o gcloud instalado e logado (gcloud auth login) com permissão para executar o job no projeto.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('homologacao', 'producao')]
    [string]$Ambiente,
    [Parameter(Position = 1)]
    [ValidateSet('acordar', 'hibernar', 'status', 'verificar')]
    [string]$Acao = 'status',
    [Parameter(Position = 2)]
    [int]$Horas = 0
)

$arquivo = Join-Path $PSScriptRoot "ambientes\$Ambiente.env"
$config = @{}
Get-Content $arquivo | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)="?([^"#]*)"?') { $config[$Matches[1]] = $Matches[2].Trim() }
}
if ($config['PROJETO'] -like 'troque-pelo-id-do-projeto*') {
    Write-Error "Ajuste PROJETO em gcp\ambientes\$Ambiente.env"
    exit 1
}
if ($Ambiente -eq 'producao' -and $Acao -in @('acordar', 'hibernar')) {
    $confirmacao = Read-Host "ATENÇÃO: PRODUÇÃO ($($config['PROJETO'])). Digite o ID do projeto para confirmar"
    if ($confirmacao -ne $config['PROJETO']) { Write-Host 'Cancelado.'; exit 1 }
}
if ($Horas -le 0) { $Horas = [int]$config['HORAS_EXTRAS_PADRAO'] }

$argumentos = if ($Acao -eq 'acordar') { "acordar,$Horas" } else { $Acao }
Write-Host "[$Ambiente] executando despertador: $argumentos (pode levar alguns minutos ao ligar o banco)..."
gcloud run jobs execute praia-despertador --project $config['PROJETO'] --region $config['REGIAO'] --args=$argumentos --wait
if ($LASTEXITCODE -eq 0) {
    Write-Host "Pronto. Log da execução: Console > Cloud Run > Jobs > praia-despertador > Execuções"
}
