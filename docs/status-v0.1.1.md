# Correção de status na v0.1.1

Na v0.1.0, o primeiro uso de `android-connect status` demorou aproximadamente um minuto segundo o relato do usuário. A saída era JSON mesmo sem `--json`, a distribuição apareceu como um objeto vazio e a descoberta USB informou que não podia substituir a variável PID.

## Causas confirmadas

- O executor declarava um parâmetro chamado `$Args`. Na reprodução em Windows PowerShell 5.1, os dois argumentos estavam em `$PSBoundParameters`, mas `$Args.Count` era zero. O processo filho recebia uma linha vazia. Uma chamada de teste a PowerShell abriu o shell e carregou seu perfil em vez de executar o comando solicitado. As consultas WSL passavam por esse mesmo executor, com timeouts sucessivos.
- A descoberta USB tentava atribuir o product ID a `$pid`. O PowerShell trata esse nome como a variável automática `$PID`, que é somente leitura.
- O módulo usbipd-win 5.3.0 retorna `HardwareId.Vid` e `HardwareId.Pid` como números. Seu formato textual observado é `04e8:6860`; a implementação só aceitava o formato `VID_...&PID_...`.
- O ramo `status` serializava JSON nas duas opções de apresentação. Além disso, usava a coleta completa, que incluía versão WSL, kernel, processos e logs.
- Passar scripts Bash através de `wsl.exe --` permitia uma interpretação adicional pelo shell padrão. A reprodução da consulta nova falhou ao expandir variáveis Bash antes da etapa pretendida. O mesmo comando funcionou com `--exec`.

O erro de distribuição vazia foi observado junto da perda dos argumentos. A listagem também dependia dos termos ingleses Running/Stopped; agora o parser preserva o texto de estado e confirma as distribuições ativas por `--list --running --quiet`.

## Correção

O executor usa `Arguments`, preserva argumentos vazios e aspas, fecha stdin e impõe prazo à leitura dos pipes. Os identificadores USB têm nomes próprios (`vendorId` e `productId`) e aceitam os campos tipados do usbipd.

`status` tem uma coleta própria. Consulta apenas a listagem WSL, os dispositivos USB e o smart socket do servidor ADB escolhido. Não inicia uma distribuição parada, não executa o cliente ADB e não reinicia servidores. A resposta usa texto por padrão e JSON apenas com `--json`. Erros ficam explícitos e produzem código de saída diferente de zero.

## Validação no ambiente alvo

Após a correção, consultas locais de leitura duraram cerca de 0,63 segundo na medição interna. A distribuição Ubuntu e o dispositivo Samsung anexado foram encontrados. Na porta 5037, a resposta continha apenas o emulador; na 5038, continha o telefone e o emulador. O tempo anterior de aproximadamente um minuto foi relatado pelo usuário; não foi obtido por um benchmark controlado da versão antiga.

Essas consultas não fizeram attach, bind, detach ou validação shell no telefone. Elas comprovam a descoberta e a leitura dos servidores existentes nesse momento, sem validar toda a conexão automática ou o Expo.

Os testes de regressão exercitam os argumentos e timeouts com processos reais, listagens localizadas, campos tipados USB e o contrato JSON do comando completo. As operações de hardware são simuladas.

## Referências

- [PowerShell: variáveis automáticas](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables)
- [WSL: comandos de listagem](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
- [ADB: serviços do smart socket](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/SERVICES.TXT)
