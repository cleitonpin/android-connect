<div align="center">

# Android Connect

Conecte um celular Android por USB ao ADB dentro do WSL2 e verifique se ele responde.

[![Testes](https://github.com/cleitonpin/android-connect/actions/workflows/test.yml/badge.svg)](https://github.com/cleitonpin/android-connect/actions/workflows/test.yml)
![Windows](https://img.shields.io/badge/host-Windows%20%2B%20WSL2-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207-5391FE)

</div>

Android Connect encontra o dispositivo USB e acompanha sua conexão pelo usbipd-win até o ADB da distribuição WSL escolhida. A CLI só considera o aparelho pronto depois de selecionar seu serial e executar um comando nele.

## O problema

Para usar um Android no WSL2, o Windows precisa compartilhar o USB pelo usbipd-win. Depois, o WSL precisa anexar e reconhecer o dispositivo, e o ADB precisa encontrá-lo no servidor correto. Mesmo quando o `attach` termina sem erro, o aparelho pode continuar ausente no `lsusb` ou no `adb devices`.

Este projeto nasceu de dois problemas observados no uso com um Galaxy A15 (SM-A155M):

1. O dispositivo aparecia como `Shared`, mas o attach terminava com `Unbind or unplug while attached`; dentro do WSL, o kernel registrava `connection closed`. O BUSID pode mudar entre conexões.
2. O USB aparecia no Linux, mas o servidor ADB padrão na porta 5037 falhava com `ADB server didn't ACK` e `Address already in use`. Um servidor separado na porta 5038 listou o celular e um emulador simultaneamente.

A causa da queda de conexão USB/IP ainda não foi esclarecida. Também falta confirmar se o conflito ADB tem relação com a rede `mirrored`. A ferramenta consulta o BUSID atual e verifica cada etapa da conexão. Quando precisa tentar outro servidor, preserva os processos ADB existentes.

## Como funciona

```text
Windows / usbipd             WSL2 / USB                ADB
  descobrir BUSID ──attach──▶ confirmar lsusb ────────▶ selecionar servidor
  conferir estado             confirmar distribuição    conferir serial
                                                          executar getprop
```

O código separa a interface da CLI, a descoberta USB e as operações WSL do gerenciamento ADB. Há também funções para as políticas de recuperação, configuração e logs. As decisões de estado podem ser testadas sem hardware; cada operação de sistema tem limites e uma verificação posterior.

## Requisitos

- Windows 10/11 com WSL2 e uma distribuição Linux.
- [usbipd-win](https://github.com/dorssel/usbipd-win) instalado no Windows.
- PowerShell 5.1 (incluído no Windows) ou PowerShell 7.
- Interoperabilidade Windows/WSL habilitada (`powershell.exe` e `wslpath` acessíveis no WSL).
- `adb` instalado na distribuição Linux.

A CLI não instala pacotes, não altera `.bashrc`/`.profile`, não reinicia WSL ou serviços e não encerra processos ADB.

## Instalar sem Git e sem clonar o repositório

No PowerShell do Windows:

```powershell
irm https://raw.githubusercontent.com/cleitonpin/android-connect/main/install.ps1 | iex
android-connect help
```

O instalador baixa os arquivos da CLI para `%LOCALAPPDATA%\Programs\AndroidConnect` e confere seus hashes SHA-256. A pasta `bin` entra no `PATH` do usuário e da sessão atual, sem exigir administrador. ADB, WSL e usbipd-win precisam estar instalados. Mesmo iniciado pelo Windows, o comando usa o ADB dentro do WSL.

No terminal WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/cleitonpin/android-connect/main/install.sh | bash
android-connect help
```

A instalação WSL salva a CLI em `~/.local/share/android-connect/versions/` e cria o comando em `~/.local/bin`. Você pode executar os dois instaladores de qualquer pasta, sem Git. Eles baixam uma tag de versão específica; para atualizar, reexecute o instalador.

O manifesto de hashes vem do mesmo repositório, por HTTPS. A conferência detecta arquivos corrompidos ou inconsistentes, mas depende da confiança neste publicador.

Se `~/.local/bin` não estiver no `PATH`, adicione-o à sessão:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

`irm` é o alias de `Invoke-RestMethod`; `iex` é o alias de `Invoke-Expression`. Juntos, eles baixam e executam código remoto. Para ler o instalador antes de executá-lo:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/cleitonpin/android-connect/main/install.ps1 -OutFile install-android-connect.ps1
# Abra e revise install-android-connect.ps1; depois:
& .\install-android-connect.ps1
```

Para não alterar o PATH no Windows, execute o arquivo com `-NoPath`. Para fixar uma versão, use `-Version v0.1.1` no PowerShell ou `ANDROID_CONNECT_VERSION=v0.1.1 bash install.sh` no WSL, depois de baixar o instalador. Nenhum perfil de shell é editado. Use `ANDROID_CONNECT_POWERSHELL=pwsh.exe` no WSL ou `$env:ANDROID_CONNECT_POWERSHELL='pwsh.exe'` no Windows para escolher PowerShell 7.

Para desenvolver a ferramenta, clone o repositório:

```bash
git clone https://github.com/cleitonpin/android-connect.git
cd android-connect
./bin/android-connect help
```

Para desinstalar, remova a pasta da instalação e o comando criado. No Windows, remova também a entrada `%LOCALAPPDATA%\Programs\AndroidConnect\bin` do PATH do usuário. As preferências em `%LOCALAPPDATA%\android-connect` ficam separadas da instalação.

## Uso rápido

```bash
android-connect                 # descobrir, conectar e validar
android-connect status          # estado atual, sem alterar o sistema
android-connect devices         # listar físicos e emuladores
android-connect doctor           # relatório de diagnóstico
android-connect doctor --json    # diagnóstico em JSON
android-connect fix              # aplicar recuperação segura
android-connect logs             # eventos recentes
android-connect disconnect       # desconectar somente o dispositivo selecionado
```

`status` mostra um resumo em texto e o tempo da consulta. Para JSON, use `android-connect status --json`. Ele não inicia distribuições paradas nem servidores ADB e não coleta logs ou informações de kernel; essa coleta fica no `doctor`. Um USB em `Attached` pode continuar ausente no ADB, e a saída mostra essa diferença.

Para conferir outro servidor já existente, por exemplo o da porta 5038:

```bash
android-connect status --port 5038
```

Se instalou a v0.1.0, reexecute o instalador para receber a correção da lentidão, da descoberta USB e da saída de `status`. A [investigação da v0.1.1](docs/status-v0.1.1.md) explica os erros encontrados e os testes de regressão.

Opções: `--device BUSID`, `--serial SERIAL`, `--distro NOME`, `--port N`, `--dry-run`, `--verbose`, `--json`, `--yes`. Use `--output CAMINHO` para exportar o relatório do doctor. `--yes` dispensa confirmações apenas nas operações classificadas como seguras; não autoriza `bind --force`, unbind ou alterações de sistema.

Se houver mais de um Android correspondente e nenhuma preferência configurada, a CLI pede que você escolha um deles. Você pode salvar essa preferência na configuração local. A identificação como Samsung, por si só, não basta para selecionar o Galaxy A15.

## Usar com Expo e React Native

`exec` configura o ambiente ADB apenas para o processo iniciado e seus filhos:

```bash
android-connect exec -- adb devices -l
android-connect exec -- npx expo run:android --device RX8XA05QK1P
android-connect exec -- npx expo start --android
```

Os argumentos do processo são encaminhados separadamente, inclusive quando contêm espaços, sem reconstruir o comando em um shell intermediário. As variáveis `ANDROID_ADB_SERVER_PORT` e `ADB_SERVER_SOCKET` selecionam o servidor apenas para o processo filho. A sessão atual e as ferramentas Expo já abertas mantêm seu ambiente. A seleção do dispositivo depende da versão e do fluxo do Expo; confira o comportamento no projeto antes de depender dela.

Ferramentas Android abertas no Windows e no WSL podem usar ambientes e servidores distintos. `exec` configura apenas o processo WSL que ele inicia; as ferramentas abertas no Windows mantêm sua própria configuração.

## Segurança e recuperação

| Estado observado | Ação da CLI |
|---|---|
| USB não compartilhado | Solicita confirmação e usa `usbipd bind` normal, que exige elevação e persiste o compartilhamento. |
| USB compartilhado | Tenta `usbipd attach --wsl --busid` com até três tentativas e valida novamente o estado. |
| USB já anexado | Confere a presença no Linux antes de consultar ADB. |
| Porta 5037 não utilizável | Procura servidor existente em portas alternativas; só inicia em porta livre e não mata outro servidor. |
| `unauthorized` | Informa que é necessário desbloquear o aparelho e aceitar a chave RSA na tela. |
| `offline`, USB ausente ou serviço parado | Mostra evidências e próximos passos; não reinicia serviço ou WSL automaticamente. |

Operações como `usbipd unbind`, `bind --force`, reinício de serviço e alterações persistentes de rede, firewall, drivers ou registro não são feitas automaticamente. Em caso de falha, `doctor` separa observações de hipóteses e mascara seriais nos relatórios compartilháveis.

## Configuração e logs

Preferências e eventos JSONL ficam em `%LOCALAPPDATA%\android-connect\` no Windows: `config.json` e `logs\events.jsonl`. A configuração inicial usa o serial histórico `RX8XA05QK1P`, o modelo esperado `SM-A155M` e VID:PID `04e8:6860` como pistas. Serial é a chave preferencial; VID/PID, descrição e BUSID são auxiliares. Edite a configuração para outra distribuição ou dispositivo.

Cada evento de log tem timestamp UTC, severidade, operação, resultado, duração e mensagem. Os relatórios mascaram seriais, caminhos de perfil e padrões sensíveis conhecidos. Antes de compartilhar um relatório, confira seu conteúdo: ele ainda pode incluir versões e detalhes do ambiente.

## Testes

Os testes de unidade usam Pester 5 para verificar a seleção do dispositivo, os estados USB e a política de portas ADB. Eles também cobrem o uso simultâneo de emulador, erros de autorização, limites de tentativas e cancelamento.

Os testes dos instaladores simulam os downloads e verificam se uma instalação pode ser repetida. Um hash inválido deve interromper a instalação e preservar a versão anterior. No CI Windows, o comando instalado em um caminho com espaços precisa responder a `help`. Os testes dos lançadores usam executáveis falsos para conferir opções e argumentos com espaços e metacaracteres, sem acessar USB.

Os testes de `status` exercitam o executor com processos Windows reais, incluindo argumentos vazios, aspas e timeout. A descoberta e a consulta usam fixtures de objetos usbipd, listagens WSL localizadas e respostas ADB. Um teste executa o comando completo em JSON com uma distribuição inexistente para verificar o contrato de erro.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Import-Module Pester -RequiredVersion 5.7.1 -Force
Invoke-Pester ./tests -CI
```

```bash
bash -n bin/android-connect install.sh tests/launcher.sh tests/installer.sh
./tests/launcher.sh
sha256sum --check SHA256SUMS
./tests/installer.sh
```

O GitHub Actions executa os testes Pester em `windows-latest` e os testes do lançador em `ubuntu-latest`. Testes unitários não provam integração com um telefone real; isso exige Windows, usbipd-win e aparelho conectado.

Ao alterar arquivos de runtime, atualize o manifesto antes de publicar uma nova tag:

```bash
sha256sum src/AndroidConnect.ps1 src/AndroidConnect.Core.psm1 bin/android-connect bin/android-connect.ps1 > SHA256SUMS
```

## Documentação

- [Arquitetura e fluxo de estados](docs/architecture.md)
- [usbipd-win: automação oficial](https://github.com/dorssel/usbipd-win/wiki/Automation)
- [Microsoft: conectar dispositivos USB ao WSL](https://learn.microsoft.com/windows/wsl/connect-usb)
- [ADB: código oficial do cliente e configuração do socket](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/commandline.cpp)

## Limites conhecidos

- A conexão física só pode ser comprovada no host Windows com o aparelho presente.
- O servidor 5038 funcionou no ambiente que motivou este projeto, mas a hipótese de interferência do modo mirrored permanece sem confirmação.
- A integração do comando `exec` com Expo depende do fluxo e da versão do Expo instalados pelo projeto.
- PowerShell 5.1 e usbipd-win devem ser validados no host alvo; a suíte de CI cobre decisões puras e o lançador, não operações de hardware.
