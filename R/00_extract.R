# =============================================================================
# 00_extract.R — da extração bruta à base mínima publicável
#
# Lê a extração de venda líquida DIRETO da pasta de origem, aplica o tratamento e
# grava só o que o modelo precisa: a fração do dia já vendida, por dia × faixa de 15 min.
#
# Saída: data/intraday_fraction.csv  (sem nenhum valor em R$)
# O CSV bruto nunca é copiado para dentro do repositório.
#
# Configuração: crie _local/config.R (pasta fora do versionamento) com
#   caminho_origem  <- "caminho/para/a/pasta/com/os/csvs"
#   filiais_excluir <- c()   # filiais que não contam na análise
# =============================================================================

library(data.table)
library(dplyr)
library(tidyr)
library(lubridate)

source(here::here("_local", "config.R"))   # caminho_origem, filiais_excluir

# Parâmetros
hora_limite <- hm("22:55") # Vendas a partir das 22h55 (hora real) não entram na venda acumulada; a venda do dia (denominador) conta o dia todo
inicio_proj <- as.POSIXct("2000-01-01 09:45:00", tz = "America/Sao_Paulo") # A projeção começa às 9h45 (vendas até ~8h40, por causa do atraso de 1h05)
fim_proj    <- as.POSIXct("2000-01-01 22:55:00", tz = "America/Sao_Paulo") # último slot da grade: 22:45

# Dados — só as 4 colunas usadas (+ filial para o filtro); o resto da extração nem é lido
dados <- fread(file.path(caminho_origem, "VW_TB_VENDA_LIQUIDA.csv"),
               select = c("Filial de Venda", "Data Cancelamento/Devolucão",
                          "Data Emissão Completa", "Tipo de Movimento",
                          "Valor Venda Expurgado"),
               encoding = "UTF-8") %>%
  filter(!`Filial de Venda` %in% filiais_excluir) %>%
  select(-`Filial de Venda`)

# Tratamento Base
dados <- dados %>%
  mutate(Data_Hora = case_when(
    `Tipo de Movimento` == "Cancelamento" ~ `Data Cancelamento/Devolucão`,
    `Tipo de Movimento` == "Venda" ~ `Data Emissão Completa`
  )) %>%
  select(-c(`Data Cancelamento/Devolucão`, `Data Emissão Completa`, `Tipo de Movimento`))

dados$Data_Hora <- as.POSIXct(dados$Data_Hora, format = "%d/%m/%Y %H:%M:%S", tz = "America/Sao_Paulo")
dados <- dados %>% arrange(Data_Hora)

# Tratamento da base venda líquida de 15 em 15 min

## Passo 1: Corrigir o delay. Adição de 1h05, pois a venda só entra na base cerca de 1 hora depois (entre 1h e 1h10)
df <- dados %>%
  mutate(
    Data_Hora_Sistema = Data_Hora + hours(1) + minutes(5),
    Data = as.Date(Data_Hora_Sistema, tz = "America/Sao_Paulo"),
    Hora_Att_Liquida_Dia = ceiling_date(Data_Hora_Sistema, unit = "15 minutes")
  ) %>%
  filter(hms::as_hms(Data_Hora) < hora_limite) # A partir da hora limite, a projeção será o valor atual da venda

## Passo 2: Gerar grid completo por dia
datas <- seq.Date(from = as.Date(min(dados$Data_Hora), tz = "America/Sao_Paulo"),
                  to   = as.Date(max(dados$Data_Hora), tz = "America/Sao_Paulo"),
                  by = "day")
horas_fmt <- format(seq.POSIXt(from = inicio_proj, to = fim_proj, by = "15 mins"),
                    "%H:%M:%S", tz = "America/Sao_Paulo")

grid <- expand.grid(Data = datas, hora_str = horas_fmt, stringsAsFactors = FALSE) %>%
  mutate(Hora_Att_Liquida_Dia = as.POSIXct(paste(Data, hora_str), tz = "America/Sao_Paulo")) %>%
  arrange(Hora_Att_Liquida_Dia)

## Passo 3: Cálculo das vendas acumuladas até o período
transacoes_acumuladas <- df %>%
  group_by(Data, Hora_Att_Liquida_Dia) %>%
  summarise(valor = sum(`Valor Venda Expurgado`), .groups = "drop") %>%
  arrange(Data, Hora_Att_Liquida_Dia) %>%
  group_by(Data) %>%
  mutate(venda_acumulada = cumsum(valor)) %>%
  ungroup()

## Passo 4: Juntar com o grid e preencher valores anteriores (forward fill)
base <- grid %>%
  left_join(transacoes_acumuladas %>% select(Data, Hora_Att_Liquida_Dia, venda_acumulada),
            by = join_by(Data, Hora_Att_Liquida_Dia)) %>%
  arrange(Data, Hora_Att_Liquida_Dia) %>%
  group_by(Data) %>%
  fill(venda_acumulada, .direction = "down") %>%
  ungroup() %>%
  mutate(venda_acumulada = replace_na(venda_acumulada, 0))

# Y: Multiplicador = fração do dia já vendida
venda_dia <- dados %>%
  mutate(Data = as.Date(Data_Hora, tz = "America/Sao_Paulo")) %>%
  group_by(Data) %>%
  summarise(Venda_Dia = sum(`Valor Venda Expurgado`, na.rm = TRUE), .groups = "drop")

# Dia da semana com rótulo fixo (weekdays() depende do idioma do sistema)
dias_pt <- c("domingo", "segunda-feira", "terça-feira", "quarta-feira",
             "quinta-feira", "sexta-feira", "sábado")

base_final <- base %>%
  left_join(venda_dia, by = join_by(Data)) %>%
  mutate(
    Multiplicador = venda_acumulada / Venda_Dia,
    Hora       = format(Hora_Att_Liquida_Dia, "%H:%M"),
    perc_dia   = (hour(Hora_Att_Liquida_Dia) * 60 + minute(Hora_Att_Liquida_Dia)) / (24 * 60),
    dia_semana = dias_pt[wday(Data)]
  ) %>%
  filter(is.finite(Multiplicador)) %>%
  # Daqui para baixo só razões: venda_acumulada e Venda_Dia (R$) não saem desta função
  transmute(Data, Hora, dia_semana, perc_dia = round(perc_dia, 6),
            Multiplicador = round(Multiplicador, 6))

fwrite(base_final, here::here("data", "intraday_fraction.csv"))

cat("Base gravada:", nrow(base_final), "linhas,", uniqueN(base_final$Data), "dias\n")
