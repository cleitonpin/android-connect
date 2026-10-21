<div align="center">

# Android Connect

**Conecte um celular Android por USB ao ADB dentro do WSL2, com diagnóstico e validação de verdade.**

[![Testes](https://github.com/cleitonpin/android-connect/actions/workflows/test.yml/badge.svg)](https://github.com/cleitonpin/android-connect/actions/workflows/test.yml)
![Windows](https://img.shields.io/badge/host-Windows%20%2B%20WSL2-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207-5391FE)

</div>

Android Connect é uma CLI local para descobrir o dispositivo USB, acompanhar seu estado no usbipd-win e preparar um servidor ADB utilizável na distribuição WSL escolhida. Ela só informa que está pronto depois de selecionar o serial físico e executar um comando real no aparelho.

## O problema

Conectar um Android ao WSL2 envolve mais de um estado independente: o Windows precisa compartilhar o USB pelo usbipd-win, o WSL precisa anexar e reconhecer o dispositivo, e o ADB precisa encontrar o telefone no servidor correto. Um `attach` bem-sucedido não garante que `lsusb` ou `adb devices` verá o aparelho.

Este projeto nasceu de dois problemas observados no uso com um Galaxy A15 (SM-A155M):

1. O dispositivo aparecia como `Shared`, mas o attach terminava com `Unbind or unplug while attached`; dentro do WSL, o kernel registrava `connection closed`. O BUSID pode mudar entre conexões.
2. O USB aparecia no Linux, mas o servidor ADB padrão na porta 5037 falhava com `ADB server didn't ACK` e `Address already in use`. Um servidor separado na porta 5038 listou o celular e um emulador simultaneamente.

A causa do fechamento USB/IP não foi identificada de forma conclusiva. A relação entre o conflito ADB e a rede `mirrored` também é uma hipótese, não uma causa confirmada. Por isso, a ferramenta redescobre o BUSID, consulta cada estado e tenta servidores alternativos sem matar processos ADB existentes.

## Como funciona

```text
Windows / usbipd             WSL2 / USB                ADB
  descobrir BUSID ──attach──▶ confirmar lsusb ────────▶ selecionar servidor
  conferir estado             confirmar distribuição    conferir serial
                                                          executar getprop
```

A implementação separa CLI e apresentação, descoberta USB, operações WSL, gerenciamento ADB, políticas de recuperação, configuração e logging. As decisões de estado são funções testáveis; operações de sistema têm limites e verificações posteriores.

## Requisitos

- Windows 10/11 com WSL2 e uma distribuição Linux.
- [usbipd-win](https://github.com/dorssel/usbipd-win) instalado no Windows.
- PowerShell 5.1 (incluído no Windows) ou PowerShell 7.
- Interoperabilidade Windows/WSL habilitada (`powershell.exe` e `wslpath` acessíveis no WSL).
- `adb` instalado na distribuição Linux.

A CLI não instala pacotes, não altera `.bashrc`/`.profile`, não reinicia WSL ou serviços e não encerra processos ADB.

## Instalar sem Git e sem clonar o repositório

No **PowerShell do Windows**, execute:

```powershell
irm https://raw.githubusercontent.com/cleitonpin/android-connect/main/install.ps1 | iex
android-connect help
```

O instalador baixa apenas os arquivos da CLI, verifica seus hashes SHA-256 e instala em `%LOCALAPPDATA%\Programs\AndroidConnect`. Ele adiciona sua pasta `bin` ao `PATH` do usuário e da sessão atual, sem exigir administrador. Não instala ADB, WSL ou usbipd-win. Os comandos continuam operando o ADB dentro do WSL.

No **terminal WSL**, execute:

```bash
curl -fsSL https://raw.githubusercontent.com/cleitonpin/android-connect/main/install.sh | bash
android-connect help
```

A instalação WSL salva a CLI em `~/.local/share/android-connect/versions/` e cria o comando em `~/.local/bin`. Nenhum dos instaladores precisa de Git ou de estar dentro de um projeto. Os arquivos baixados são de uma tag de versão específica; reexecute o instalador para atualizar a versão distribuída por ele. O manifesto de hashes é servido pelo mesmo repositório via HTTPS: a verificação detecta arquivos corrompidos ou inconsistentes e exige confiança neste publicador.

Se `~/.local/bin` não estiver no `PATH`, adicione-o à sessão:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

`irm` é o alias de `Invoke-RestMethod`; `iex` é o alias de `Invoke-Expression`. A combinação executa código remoto. Se preferir revisar antes, baixe o instalador, leia o arquivo e execute-o em seguida:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/cleitonpin/android-connect/main/install.ps1 -OutFile install-android-connect.ps1
# Abra e revise install-android-connect.ps1; depois:
& .\install-android-connect.ps1
```

Para não alterar o PATH no Windows, execute o arquivo com `-NoPath`. Para fixar uma versão, use `-Version v0.1.0` no PowerShell ou `ANDROID_CONNECT_VERSION=v0.1.0 bash install.sh` no WSL, depois de baixar o instalador. Nenhum perfil de shell é editado. Use `ANDROID_CONNECT_POWERSHELL=pwsh.exe` no WSL ou `$env:ANDROID_CONNECT_POWERSHELL='pwsh.exe'` no Windows para escolher PowerShell 7.

Para desenvolver a ferramenta, o clone continua disponível:

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

Opções: `--device BUSID`, `--serial SERIAL`, `--distro NOME`, `--port N`, `--dry-run`, `--verbose`, `--json`, `--yes`. `--output CAMINHO` exporta o relatório do doctor. `--yes` só pula confirmações de operações classificadas como seguras; não autoriza `bind --force`, unbind ou alterações de sistema.

Se mais de um Android corresponder aos critérios e não houver preferência configurada, a CLI pede seleção em modo interativo. A preferência pode ser salva na configuração local. Um Samsung não é considerado automaticamente o Galaxy A15.

## Usar com Expo e React Native

`exec` configura o ambiente ADB apenas para o processo iniciado e seus filhos:

```bash
android-connect exec -- adb devices -l
android-connect exec -- npx expo run:android --device RX8XA05QK1P
android-connect exec -- npx expo start --android
```

O comando não usa shell intermediário para reconstruir os argumentos do processo; argumentos com espaços são encaminhados separadamente. O ambiente inclui `ANDROID_ADB_SERVER_PORT` e `ADB_SERVER_SOCKET` para selecionar o servidor. Isso não altera a sessão atual nem ferramentas Expo já abertas. O comportamento de seleção do device ainda depende da versão e do fluxo do Expo; valide no projeto antes de depender da seleção automática.

Quando Windows e WSL executam ferramentas Android ao mesmo tempo, elas podem ter ambientes e servidores distintos. `exec` só controla o processo WSL iniciado por ele; não configura ferramentas iniciadas no Windows.

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

Os logs incluem timestamp UTC, severidade, operação, resultado, duração e mensagem. Relatórios mascaram serial, caminhos de perfil e padrões sensíveis conhecidos. Revise o relatório antes de compartilhá-lo; ele pode conter versões e detalhes do ambiente.

## Testes

Os testes de unidade usam Pester 5 e cobrem seleção de dispositivo, estados USB, política ADB/portas, presença de emulador, erros de autorização, retries limitados e cancelamento. Os testes de instalação simulam downloads, verificam repetição, rejeição de hashes inválidos e preservação da instalação anterior. O CI Windows também executa `help` pelo comando instalado em um caminho com espaços. Os testes dos lançadores verificam opções e argumentos com espaços/metacaracteres usando executáveis falsos; não acessam USB.

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
