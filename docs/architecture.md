# Arquitetura

- bin/android-connect: ponte WSL → Windows PowerShell, normaliza flags e resolve caminho independente do cwd.
- src/AndroidConnect.ps1: adaptadores de processos, usbipd, WSL/ADB, máquina de conexão, comandos e saída.
- src/AndroidConnect.Core.psm1: funções puras para classificação de estados, seleção de porta e política de ações.
- tests: testes Pester sem dispositivos ou mutações reais.
- install.ps1 / install.sh: instalação independente de clone, com downloads de uma tag, validação SHA-256 e promoção dos arquivos verificados.
- bin/android-connect.ps1: entrada Windows que normaliza opções e mantém os argumentos do comando filho separados.

## Distribuição

O bootstrap da branch main aponta para uma tag de versão explícita (`v0.1.1`). Ele baixa uma lista fixa de quatro arquivos e o manifesto SHA256SUMS. O manifesto não fornece uma assinatura independente: a origem continua sendo o publicador no GitHub por HTTPS. Uma falha de download ou hash interrompe a promoção e mantém a instalação anterior.

No Windows o comando é um shim CMD em um diretório do PATH do usuário, sem editar perfis PowerShell. No WSL o comando é um symlink em ~/.local/bin. O instalador WSL informa como ajustar o PATH da sessão se necessário; ele não consegue alterar o ambiente do shell pai por um pipe.

## Decisões

1. Windows PowerShell 5.1 como base, sem dependência externa; PowerShell 7 pode ser selecionado. Isso cobre Windows comum e aproveita o módulo do usbipd.
2. Estado USB vem do Get-UsbipdDevice do módulo que acompanha a versão instalada, pois a tabela de usbipd list pode localizar ou truncar texto. usbipd bind exige elevação; attach não.
3. ADB mantém seu servidor. A conexão por variáveis de sessão/processo evita configuração global e preserva emuladores. Porta alternativa é persistida só depois de validar aparelho e modelo.
4. O fluxo é idempotente: não faz detach quando Attached, não reinicia serviço/WSL e não executa kill-server. Attach tem retries limitados.
5. Serial é a identidade preferida. VID/PID e BUSID descobrem candidatos; múltiplos candidatos pedem seleção e o modelo obtido do Android precisa corresponder à preferência.
6. A hipótese de interferência Windows/WSL/mirrored só aparece como hipótese enquanto PID/listener não identificar o processo.

## Consulta de status

`status` usa a listagem WSL, os objetos tipados do usbipd e uma consulta `host:devices-l` ao smart socket ADB da porta selecionada. Não executa o cliente `adb`, que poderia iniciar um servidor ausente ou substituir um servidor de versão diferente. A consulta ADB só acontece se a distribuição já estiver em execução. A coleta de kernel, processos e logs fica no `doctor`.

O executor recebe `Arguments`, fecha stdin e limita tanto o processo quanto a leitura dos pipes. `WSL_UTF8=1` vale apenas no processo filho; a configuração global do host não é alterada. Comandos Linux usam `--exec` para impedir uma passagem adicional pelo shell padrão.

Os testes de regressão incluem processos Windows reais para argumentos e timeout, os formatos tipados do usbipd, listagens WSL localizadas e a saída JSON do comando completo. A investigação do primeiro problema de uso está em [status-v0.1.1.md](status-v0.1.1.md).
