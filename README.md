# Podcasts for KOReader

Plugin KOReader para cadastrar feeds RSS/Atom, baixar episódios e reproduzi-los
com o KinAMP. O player precisa estar instalado e habilitado separadamente.

## Estado atual

Versão 0.3.6:

- biblioteca em grade, com até quatro podcasts por linha, capa do feed e nome
  em fonte de 14 pt; feeds sem imagem usam uma capa substituta e as capas mostram
  a quantidade de episódios não tocados quando maior que zero;
- ação na lista de episódios para marcar todos como tocados de uma só vez;
- imagens RSS/Atom são guardadas localmente em `podcasts/artwork/`; para feeds
  já inscritos, use **Atualizar** uma vez para buscar as capas. São aceitas
  imagens JPEG/PNG de até 4 MiB;
- barra de tarefas na biblioteca com atalhos para adicionar feed, atualizar
  feeds, abrir os controles de reprodução e consultar o diagnóstico do player;
- os quatro atalhos ficam em uma faixa inferior própria, com rótulos e ícones
  SVG incluídos no plugin; a lista de feeds e a paginação permanecem acima dela;
- mensagem de orientação quando a biblioteca ainda não tem feeds;
- cadastro, atualização e remoção de feeds;
- feeds de até 8 MiB, mantendo no máximo os 500 primeiros episódios na ordem
  recebida do RSS/Atom (normalmente do mais recente para o mais antigo);
- leitura de RSS 2.0 e Atom com itens que declarem um enclosure de áudio;
- download para `koreader/podcasts/`, com gravação em arquivo temporário; os
  caminhos são gravados em forma absoluta, porque o KinAMP roda a partir de
  `/mnt/us/KinAMP` e não encontraria um caminho relativo;
- migração automática dos caminhos relativos salvos pela 0.2.0 ao abrir a
  biblioteca;
- validação do arquivo baixado: o plugin recusa páginas HTML, JSON, XML e
  qualquer conteúdo que não seja MP3, M4A/MP4, FLAC, WAV ou OGG Vorbis (Ogg
  Opus é recusado porque o decodificador do KinAMP não o suporta). A extensão é
  escolhida pelo conteúdo real, não pela URL, porque o KinAMP escolhe o
  decodificador pela extensão;
- reprodução de arquivos baixados pela fila do KinAMP;
- gravação da posição de reprodução e retomada aproximada;
- vigia de reprodução: se o KinAMP abrir o episódio mas não reportar duração
  (sinal de que o decodificador falhou) ou se a posição parar de avançar com o
  player dizendo que está tocando, o plugin tenta parar o player e avisa, em vez
  de deixar o daemon preso;
- atalho **Diagnóstico** na barra inferior, com o estado do backend e do player.

O download é feito para arquivo, não mantido inteiro na memória. O diálogo mostra
progresso quando o feed informa o tamanho do enclosure. A chamada HTTP usada
nesta versão é síncrona; durante um download longo, a interação com a interface
pode ficar limitada. O cancelamento de download ainda não existe.

O KinAMP mantém **uma única fila**. Ao tocar um episódio, a fila de músicas que
estiver no KinAMP é substituída pela lista de episódios baixados - é o mesmo
comportamento da tela de playlist do próprio KinAMP.

## Instalação para desenvolvimento

Copie `podcast.koplugin/` para `koreader/plugins/` ou para a pasta de plugins
externos do KOReader e reinicie o aplicativo. Instale e habilite também uma
versão compatível do KinAMP. O plugin acessa a API Lua interna
`kinamp_backend.play_from_index`; ela não é uma API pública estável, portanto
atualizações do KinAMP podem exigir ajustes em `kinamp_client.lua`.

O áudio baixado fica em:

```text
<diretório de dados do KOReader>/podcasts/
```

## Diagnóstico de problemas de reprodução

1. Abra **Podcasts**, toque em **Diagnóstico** na barra inferior e anote o estado mostrado.
2. Ao atualizar de uma versão anterior, encerre uma instância presa do player
   (`killall KinAMP-minimal`) antes de testar. O plugin só inicia uma instância
   nova quando não há nenhuma escutando o FIFO; um daemon travado continua
   aceitando comandos e precisa ser encerrado.
3. Os logs úteis são:
   - `koreader/crash.log` (no Kindle: `/mnt/us/koreader/crash.log`), com as
     linhas `Podcasts: ...`;
   - `/mnt/us/KinAMP/kinamp.log`, onde o KinAMP-minimal registra o que tentou
     tocar e eventuais erros do decodificador. `Failed to open file with
     miniaudio ... (Result: -7)` significa arquivo não encontrado: era o que
     acontecia na 0.2.0, que salvava caminhos relativos.
4. Se um episódio baixado antes da versão 0.2.0 não tocar, apague o download
   (**Delete downloaded file**) e baixe de novo: ele pode ter sido salvo como
   uma página de erro do servidor.

Se o KinAMP-minimal ficar sem responder, encerre-o (`killall KinAMP-minimal`);
o próximo play inicia uma instância nova.

## Testes locais

Com LuaJIT instalado, rode na pasta pai do plugin:

```sh
luajit podcast.koplugin/tests/test_feed_parser.lua
luajit podcast.koplugin/tests/test_audio_probe.lua
luajit podcast.koplugin/tests/test_kinamp_client.lua
luajit podcast.koplugin/tests/test_podcast_library.lua
luajit podcast.koplugin/tests/test_podcast_artwork.lua
```

Os testes cobrem RSS 2.0, Atom, XML inválido, a identificação dos formatos de
áudio, o vigia de reprodução (retomada, arquivo travado, fila fria e fim do
episódio) e a gravação/migração dos caminhos absolutos da biblioteca. Os módulos de UI, rede e áudio dependem do ambiente KOReader e devem
ser testados no emulador ou em um Kindle com jailbreak.

## Licença

GPL-3.0, para manter compatibilidade com a integração e o código do KinAMP.
Consulte <https://www.gnu.org/licenses/gpl-3.0.txt> para o texto da licença.
