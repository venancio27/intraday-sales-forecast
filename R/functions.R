# =============================================================================
# functions.R — funções de apoio à análise (analysis/01-forecast.Rmd)
# =============================================================================

# Função para calcular métricas de avaliação
# Cada família de modelo tem um predict() diferente; o despacho por classe resolve isso.
# As métricas vêm do yardstick (rsq_trad = R² tradicional, 1 - SS_res/SS_tot).
avaliar_modelos <- function(modelos, dados_teste, alvo) {

  resultados <- data.frame()

  for (i in seq_along(modelos)) {
    modelo <- modelos[[i]]
    preds  <- prever(modelo, dados_teste)
    real   <- dados_teste[[alvo]]

    aic_value <- tryCatch(AIC(modelo), error = function(e) NA_real_)  # árvores e ML não têm AIC

    resultados <- rbind(resultados, data.frame(
      Modelo       = names(modelos)[i],
      ME           = round(mean(preds - real), 4),
      Median_Error = round(median(preds - real), 4),
      MAE          = round(yardstick::mae_vec(real, preds), 4),
      RMSE         = round(yardstick::rmse_vec(real, preds), 4),
      R2           = round(yardstick::rsq_trad_vec(real, preds), 4),
      AIC          = round(aic_value, 1)
    ))
  }

  resultados
}

# Previsão da fração vendida, qualquer que seja a família do modelo
prever <- function(modelo, dados) {
  if (inherits(modelo, "rpart") || inherits(modelo, "rq")) {
    as.numeric(predict(modelo, newdata = dados))
  } else if (inherits(modelo, "lgb.Booster") || inherits(modelo, "xgb.Booster")) {
    as.numeric(predict(modelo, matriz_ml(dados)))
  } else if (inherits(modelo, "tobit")) {
    # predict() do Tobit devolve o preditor latente; a fórmula publicada é limitada a 0-1
    pmin(pmax(as.numeric(predict(modelo, newdata = dados, type = "response")), 0), 1)
  } else {
    as.numeric(predict(modelo, newdata = dados, type = "response"))
  }
}

# Candidato: polinômio estimado por GLM Gama com link identidade (minimiza o erro relativo).
# O link identidade exige valores iniciais; os do OLS bastam.
ajustar_gama <- function(formula, dados) {
  glm(formula, family = Gamma(link = "identity"), data = dados,
      start = coef(lm(formula, data = dados)))
}

# Candidato: logit fracionário (quasi-binomial). A previsão fica sempre entre 0 e 1.
# Cancelamentos fazem a fração passar levemente de 100% no fim da noite (máx. 100,5%);
# o logit exige 0-1, então o alvo é limitado só no ajuste.
ajustar_logit <- function(formula, dados) {
  dados$Multiplicador <- pmin(pmax(dados$Multiplicador, 0), 1)
  glm(formula, family = quasibinomial(link = "logit"), data = dados)
}

# Matriz de entrada dos modelos de ML: as MESMAS variáveis do polinômio
matriz_ml <- function(dados) {
  cbind(perc_dia = dados$perc_dia,
        sabado   = as.numeric(as.character(dados$sabado)),
        domingo  = as.numeric(as.character(dados$domingo)))
}

# O modelo cabe numa fórmula de Tableau / Power BI / Excel? Quantos parâmetros?
descrever_formula <- function(modelo) {
  if (inherits(modelo, "lgb.Booster") || inherits(modelo, "xgb.Booster")) {
    n <- if (inherits(modelo, "lgb.Booster")) modelo$current_iter() else xgboost::xgb.get.num.boosted.rounds(modelo)
    list(formula = "Não (centenas de árvores)", parametros = paste(n, "árvores"))
  } else if (inherits(modelo, "gam")) {
    list(formula = "Não na prática (splines penalizadas)", parametros = paste(length(coef(modelo)), "coef. de base"))
  } else if (inherits(modelo, "rpart")) {
    list(formula = "Sim (IFs aninhados)", parametros = paste(sum(modelo$frame$var == "<leaf>"), "folhas"))
  } else if (inherits(modelo, "glm")) {
    forma <- switch(modelo$family$link,
                    identity = "Sim (polinômio)",
                    logit    = "Sim (1 / (1 + EXP(-polinômio)))",
                    log      = "Sim (EXP do polinômio)",
                    "mu^0"   = "Sim (EXP do polinômio)",   # Tweedie com link.power = 0
                    inverse  = "Sim (1 / polinômio)",
                    "Sim")
    list(formula = forma, parametros = paste(length(coef(modelo)), "coef."))
  } else if (inherits(modelo, "tobit")) {
    list(formula = "Sim (polinômio limitado a 0-1)", parametros = paste(length(coef(modelo)), "coef."))
  } else {
    list(formula = "Sim (polinômio)", parametros = paste(length(coef(modelo)), "coef."))
  }
}

# Erro % da projeção do fechamento.
# Projeção = venda_acumulada / previsão  e  real = venda_acumulada / Multiplicador, logo
# projeção / real - 1 = Multiplicador / previsão - 1  (o valor em R$ se cancela)
erro_fechamento <- function(multiplicador, previsao) {
  100 * (multiplicador / abs(previsao) - 1)
}

# Horário confiável: primeiro slot a partir do qual o erro de TODOS os slots seguintes
# fica abaixo do limiar. rev(cummax(rev(erro))) é o maior erro daquele slot até o fim do dia.
# Se o limiar nunca se sustenta, NA.
primeiro_sustentado <- function(hora, erro, limiar) {
  ok <- which(rev(cummax(rev(erro))) < limiar)
  if (length(ok)) hora[min(ok)] else NA_character_
}

# Erro de cada slot = média, sobre os dias, de |projeção / real - 1| x 100.
# Devolve o erro por slot e o horário confiável.
horario_confiavel <- function(dados, previsao, limiar = 10) {
  por_slot <- dados |>
    dplyr::mutate(erro = abs(erro_fechamento(Multiplicador, previsao))) |>
    dplyr::group_by(Hora, perc_dia) |>
    dplyr::summarise(erro = mean(erro), .groups = "drop") |>
    dplyr::arrange(perc_dia)
  list(por_slot = por_slot,
       hora     = primeiro_sustentado(por_slot$Hora, por_slot$erro, limiar))
}

# Horário "HH:MM" -> minutos do dia (para ordenar e desenhar).
# Modelo que nunca fica confiável (NA) vira Inf: entra no fim da fila.
hora_para_min <- function(hora) {
  ifelse(is.na(hora), Inf,
         as.numeric(substr(hora, 1, 2)) * 60 + as.numeric(substr(hora, 4, 5)))
}

# Gera o campo calculado do Tableau a partir dos coeficientes do modelo
# (o polinômio; no logit ele entra dentro de 1 / (1 + EXP(-...)))
formula_tableau <- function(modelo) {
  b <- coef(modelo)
  termo <- function(nome) {
    nome |>
      sub(pattern = "I(perc_dia^2)", replacement = "[% Dia]^2", fixed = TRUE) |>
      sub(pattern = "I(perc_dia^3)", replacement = "[% Dia]^3", fixed = TRUE) |>
      sub(pattern = "perc_dia", replacement = "[% Dia]", fixed = TRUE) |>
      sub(pattern = "sabado1", replacement = "[Sábado]", fixed = TRUE) |>
      sub(pattern = "domingo1", replacement = "[Domingo]", fixed = TRUE) |>
      gsub(pattern = ":", replacement = " * ", fixed = TRUE)
  }
  partes <- c(sprintf("%.4f", b[1]),
              sprintf("%+.4f * %s", b[-1], vapply(names(b)[-1], termo, character(1))))
  paste(partes, collapse = "\n")
}

# Tema dos gráficos (paleta de referência validada; os 3 primeiros slots passam CVD par a par)
# Ordem fixa: modelo, segundo melhor de fórmula, teto de referência
paleta <- c("#2a78d6", "#eb6834", "#1baf7a")

tema <- function() {
  ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      plot.background  = ggplot2::element_rect(fill = "#fcfcfb", colour = NA),
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major = ggplot2::element_line(colour = "#e6e5e0", linewidth = 0.3),
      text             = ggplot2::element_text(colour = "#0b0b0b"),
      axis.text        = ggplot2::element_text(colour = "#52514e"),
      plot.title       = ggplot2::element_text(face = "bold"),
      plot.subtitle    = ggplot2::element_text(colour = "#52514e"),
      plot.caption     = ggplot2::element_text(colour = "#52514e", hjust = 0),
      legend.position  = "top",
      legend.title     = ggplot2::element_blank()
    )
}
