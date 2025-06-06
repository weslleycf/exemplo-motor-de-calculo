IF OBJECT_ID('dbo.RegrasCalculoContabil', 'U') IS NOT NULL
BEGIN
    -- Antes de dropar, verifique se não há dependências como FKs de RegrasCalculoPartidas
    -- Se houver, drope a tabela filha primeiro ou altere as FKs.
    -- Ex: ALTER TABLE RegrasCalculoPartidas DROP CONSTRAINT FK_RegrasCalculoPartidas_Regra;
    -- DROP TABLE dbo.RegrasCalculoContabil; -- Cuidado ao executar em produção
END
GO
CREATE TABLE RegrasCalculoContabil (
    RegraID INT IDENTITY(1,1) PRIMARY KEY,
    RegraConceito VARCHAR(100) NOT NULL,      -- Ex: 'VENDA_MERCADORIA', 'PAGTO_FORNECEDOR'
    DescricaoRegra NVARCHAR(255) NOT NULL,
    EmpresaEspecificaID VARCHAR(50) NULL,     -- NULL para regras padrão, ID da empresa para específicas
    FormulaValorBase NVARCHAR(MAX) NOT NULL,  -- Fórmula SQL para calcular o VALOR PRINCIPAL da transação
    CondicaoExecucao NVARCHAR(MAX) NULL,      -- Condição SQL para executar a regra
    OrdemExecucao INT NOT NULL DEFAULT 0,     -- Ordem de execução dos CONCEITOS de regra
    Ativa BIT NOT NULL DEFAULT 1,
    DataCriacao DATETIME DEFAULT GETDATE(),
    DataModificacao DATETIME DEFAULT GETDATE()
);
GO
-- Recriar Índices se a tabela foi dropada
CREATE INDEX IX_RegrasCalculoContabil_ConceitoEmpresaAtiva
ON RegrasCalculoContabil(RegraConceito, EmpresaEspecificaID, Ativa);

CREATE UNIQUE INDEX UQ_RegrasCalculoContabil_ConceitoPadrao
ON RegrasCalculoContabil(RegraConceito)
WHERE EmpresaEspecificaID IS NULL;

CREATE UNIQUE INDEX UQ_RegrasCalculoContabil_ConceitoEmpresaEspecifica
ON RegrasCalculoContabil(RegraConceito, EmpresaEspecificaID)
WHERE EmpresaEspecificaID IS NOT NULL;
GO



IF OBJECT_ID('dbo.RegrasCalculoPartidas', 'U') IS NOT NULL
    DROP TABLE dbo.RegrasCalculoPartidas; -- Cuidado
GO
CREATE TABLE RegrasCalculoPartidas (
    PartidaID INT IDENTITY(1,1) PRIMARY KEY,
    RegraID INT NOT NULL,
    TipoPartida CHAR(1) NOT NULL CHECK (TipoPartida IN ('D', 'C')), -- 'D' para Débito, 'C' para Crédito
    ContaContabil VARCHAR(50) NOT NULL,     -- Código da conta contábil a ser afetada
    PercentualSobreValorBase DECIMAL(18, 4) NOT NULL DEFAULT 100.00, -- Percentual do FormulaValorBase a ser aplicado
                                                                 -- Ex: 100.00 para 100%, 50.00 para 50%.
                                                                 -- Pode ser > 100% se o valor base for uma referência.
    HistoricoPadraoSugerido NVARCHAR(255) NULL, -- Histórico específico para esta perna do lançamento
    CONSTRAINT FK_RegrasCalculoPartidas_Regra FOREIGN KEY (RegraID) REFERENCES RegrasCalculoContabil(RegraID) ON DELETE CASCADE
);
GO
CREATE INDEX IX_RegrasCalculoPartidas_RegraID ON RegrasCalculoPartidas(RegraID);
GO




-- Tabela de Lançamentos Contábeis (Exemplo)
IF OBJECT_ID('dbo.LancamentosContabeis', 'U') IS NULL
BEGIN
    CREATE TABLE LancamentosContabeis (
        LancamentoID BIGINT IDENTITY(1,1) PRIMARY KEY,
        DataLancamento DATETIME NOT NULL,
        PeriodoID INT NOT NULL,
        EmpresaID VARCHAR(50) NOT NULL,
        RegraID INT NULL, -- Qual regra gerou este lançamento
        NumeroLote INT NULL, -- Para agrupar todas as partidas de uma mesma execução de regra
        ContaContabil VARCHAR(50) NOT NULL,
        Historico NVARCHAR(500) NULL,
        ValorDebito DECIMAL(18,2) NOT NULL DEFAULT 0,
        ValorCredito DECIMAL(18,2) NOT NULL DEFAULT 0,
        CONSTRAINT FK_Lancamentos_Regra FOREIGN KEY (RegraID) REFERENCES RegrasCalculoContabil(RegraID),
        CONSTRAINT CK_DebitoCredito CHECK (ValorDebito >= 0 AND ValorCredito >= 0 AND (ValorDebito > 0 OR ValorCredito > 0) AND (ValorDebito = 0 OR ValorCredito = 0)) -- Garante que ou é débito ou é crédito
    );
    CREATE INDEX IX_LancamentosContabeis_PeriodoEmpresa ON LancamentosContabeis(PeriodoID, EmpresaID);
END
GO

-- Tabela PlanoContas (Exemplo)
IF OBJECT_ID('dbo.PlanoContas', 'U') IS NULL
BEGIN
    CREATE TABLE PlanoContas (
        PlanoContasUID INT IDENTITY(1,1) PRIMARY KEY,
        EmpresaID VARCHAR(50) NOT NULL,
        ContaID VARCHAR(50) NOT NULL,
        DescricaoConta NVARCHAR(255) NOT NULL,
        Natureza CHAR(1) NOT NULL CHECK (Natureza IN ('D', 'C')), -- D=Devedora, C=Credora
        CONSTRAINT UQ_PlanoContas_EmpresaConta UNIQUE (EmpresaID, ContaID)
    );
END
GO



IF OBJECT_ID('dbo.LogExecucaoRegras', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LogExecucaoRegras (
        LogID BIGINT IDENTITY(1,1) PRIMARY KEY,
        ExecutionRunID UNIQUEIDENTIFIER NOT NULL, -- Identificador único para toda uma execução da SP
        NumeroLote INT NULL,                      -- Número do lote de lançamento contábil gerado (se aplicável)
        DataProcessamento DATETIME2 NOT NULL DEFAULT GETDATE(),
        PeriodoID INT NOT NULL,
        EmpresaID VARCHAR(50) NOT NULL,
        RegraID INT NOT NULL,                     -- ID da regra principal processada
        RegraConceito VARCHAR(100) NOT NULL,
        DescricaoRegraProcessada NVARCHAR(255) NULL,
        CondicaoExecucaoDaRegra NVARCHAR(MAX) NULL, -- A condição que foi avaliada
        CondicaoSatisfeita BIT NULL,              -- Resultado da avaliação da condição
        FormulaValorBaseDaRegra NVARCHAR(MAX) NULL, -- A fórmula que foi usada
        ValorBaseCalculado DECIMAL(18,2) NULL,
        TotalDebitosGerados DECIMAL(18,2) NULL,   -- Soma dos débitos gerados pela regra
        TotalCreditosGerados DECIMAL(18,2) NULL,  -- Soma dos créditos gerados pela regra
        StatusExecucao VARCHAR(50) NOT NULL,      -- Ex: 'SUCESSO', 'FALHA_CONDICAO', 'ERRO_FORMULA_BASE', 'ERRO_PARTIDAS_INVALIDAS', 'ERRO_GERAL'
        MensagemDetalhada NVARCHAR(MAX) NULL,     -- Mensagem de erro ou detalhes adicionais
        Simulacao BIT NOT NULL                    -- Indica se foi uma execução em modo de simulação
    );

    CREATE INDEX IX_LogExecucaoRegras_RunID ON dbo.LogExecucaoRegras(ExecutionRunID);
    CREATE INDEX IX_LogExecucaoRegras_RegraPeriodoEmpresa ON dbo.LogExecucaoRegras(RegraID, PeriodoID, EmpresaID, DataProcessamento);
    CREATE INDEX IX_LogExecucaoRegras_StatusData ON dbo.LogExecucaoRegras(StatusExecucao, DataProcessamento);

    PRINT 'Tabela LogExecucaoRegras criada.';
END
GO


CREATE OR ALTER PROCEDURE dbo.sp_ExecutarRegrasContabeisComPartidasDobradas
    @P_PeriodoID INT,
    @P_EmpresaID VARCHAR(50),
    @P_Simulacao BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LogMensagem NVARCHAR(MAX);
    DECLARE @DataHoraAtual VARCHAR(23);
    DECLARE @NumeroLoteAtual INT;
    DECLARE @ExecutionRunID UNIQUEIDENTIFIER = NEWID(); -- ID único para esta execução da SP

    -- Obter/gerar número de lote
    IF @P_Simulacao = 0
    BEGIN
        -- Em um ambiente de alta concorrência, considere usar um SEQUENCE object para @NumeroLoteAtual
        SELECT @NumeroLoteAtual = ISNULL(MAX(NumeroLote), 0) + 1 FROM LancamentosContabeis WITH (TABLOCKX, HOLDLOCK);
    END
    ELSE
    BEGIN
        SELECT @NumeroLoteAtual = ISNULL(MAX(NumeroLote), 0) + 1 FROM LancamentosContabeis; -- Para simulação, apenas lê
    END

    DECLARE @RegrasCabecalhoParaExecucao TABLE (
        RegraID INT PRIMARY KEY, RegraConceito VARCHAR(100), OrdemExecucao INT,
        DescricaoRegra NVARCHAR(255), FormulaValorBase NVARCHAR(MAX), CondicaoExecucao NVARCHAR(MAX)
    );

    WITH RegrasPriorizadas AS (
        SELECT rc.RegraID, rc.RegraConceito, rc.OrdemExecucao, rc.DescricaoRegra, rc.FormulaValorBase, rc.CondicaoExecucao,
               ROW_NUMBER() OVER (PARTITION BY rc.RegraConceito ORDER BY CASE WHEN rc.EmpresaEspecificaID = @P_EmpresaID THEN 0 ELSE 1 END ASC) as Prioridade
        FROM RegrasCalculoContabil rc
        WHERE rc.Ativa = 1 AND (rc.EmpresaEspecificaID = @P_EmpresaID OR rc.EmpresaEspecificaID IS NULL)
    )
    INSERT INTO @RegrasCabecalhoParaExecucao
    SELECT RegraID, RegraConceito, OrdemExecucao, DescricaoRegra, FormulaValorBase, CondicaoExecucao
    FROM RegrasPriorizadas WHERE Prioridade = 1;

    SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Iniciando processamento (RunID: ', CAST(@ExecutionRunID AS VARCHAR(36)) ,'). Empresa: ', @P_EmpresaID, ', Período: ', @P_PeriodoID, ', Lote: ', @NumeroLoteAtual, IIF(@P_Simulacao=1, ' (SIMULAÇÃO)', ''));

    IF NOT EXISTS (SELECT 1 FROM @RegrasCabecalhoParaExecucao)
    BEGIN
        SET @LogMensagem = 'Nenhuma regra aplicável encontrada para os critérios fornecidos.';
        PRINT CONCAT(@DataHoraAtual, ' - INFO: ', @LogMensagem);
        INSERT INTO dbo.LogExecucaoRegras (ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, StatusExecucao, MensagemDetalhada, Simulacao)
        VALUES (@ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, 0, 'N/A_SETUP', 'INFO', @LogMensagem, @P_Simulacao);
        RETURN;
    END

    DECLARE @RegraID_Current INT, @RegraConceito_Current VARCHAR(100), @DescricaoRegra_Current NVARCHAR(255),
            @FormulaValorBase_Current NVARCHAR(MAX), @CondicaoExecucao_Current_Text NVARCHAR(MAX); -- Renomeado para evitar conflito com a variável BIT
    DECLARE @Partida_TipoPartida CHAR(1), @Partida_ContaContabil VARCHAR(50),
            @Partida_Percentual DECIMAL(18,4), @Partida_HistoricoSugerido NVARCHAR(255);
    DECLARE @SQL_Dynamic NVARCHAR(MAX), @Parametros_Definition NVARCHAR(500),
            @CondicaoSatisfeita_Result BIT, @ValorBaseCalculado_Result DECIMAL(18,2), @ValorPartidaCalculado DECIMAL(18,2);
    DECLARE @TotalDebitosLote_Regra DECIMAL(18,2), @TotalCreditosLote_Regra DECIMAL(18,2);
    DECLARE @StatusExecucaoAtual VARCHAR(50);

    DECLARE CursorRegrasCabecalho CURSOR LOCAL FAST_FORWARD FOR
        SELECT RegraID, RegraConceito, DescricaoRegra, FormulaValorBase, CondicaoExecucao
        FROM @RegrasCabecalhoParaExecucao ORDER BY OrdemExecucao, RegraID;

    OPEN CursorRegrasCabecalho;
    FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ValorBaseCalculado_Result = NULL;
        SET @CondicaoSatisfeita_Result = 1; -- Default para regras sem condição explícita
        SET @TotalDebitosLote_Regra = 0;
        SET @TotalCreditosLote_Regra = 0;
        SET @StatusExecucaoAtual = NULL;
        SET @LogMensagem = NULL;
        SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);

        IF @P_Simulacao = 0 BEGIN TRANSACTION RegraExecucao;

        BEGIN TRY
            -- 1. Avaliar Condição de Execução da Regra Principal
            IF @CondicaoExecucao_Current_Text IS NOT NULL AND LTRIM(RTRIM(@CondicaoExecucao_Current_Text)) <> ''
            BEGIN
                BEGIN TRY
                    SET @SQL_Dynamic = N'SELECT @CondicaoResult_OUT = CASE WHEN (' + @CondicaoExecucao_Current_Text + N') THEN 1 ELSE 0 END;';
                    SET @Parametros_Definition = N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @CondicaoResult_OUT BIT OUTPUT';
                    EXEC sp_executesql @SQL_Dynamic, @Parametros_Definition, @P_PeriodoID, @P_EmpresaID, @CondicaoSatisfeita_Result OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @StatusExecucaoAtual = 'ERRO_CONDICAO_SQL';
                    SET @LogMensagem = CONCAT('Falha ao avaliar CondicaoExecucao SQL: ', @CondicaoExecucao_Current_Text, '. Erro: ', ERROR_MESSAGE());
                    THROW; -- Pula para o CATCH principal da regra
                END CATCH
            END

            IF @CondicaoSatisfeita_Result = 0
            BEGIN
                SET @StatusExecucaoAtual = 'FALHA_CONDICAO';
                SET @LogMensagem = CONCAT('Condição (', LEFT(ISNULL(@CondicaoExecucao_Current_Text,'N/A'),200), '...) não satisfeita.');
                PRINT CONCAT(@DataHoraAtual, ' - INFO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao; -- Rollback se transação foi iniciada
                -- Loga e continua para a próxima regra
                INSERT INTO dbo.LogExecucaoRegras (ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, DescricaoRegraProcessada, CondicaoExecucaoDaRegra, CondicaoSatisfeita, StatusExecucao, MensagemDetalhada, Simulacao)
                VALUES (@ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @CondicaoExecucao_Current_Text, @CondicaoSatisfeita_Result, @StatusExecucaoAtual, @LogMensagem, @P_Simulacao);
                FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text;
                CONTINUE;
            END

            -- 2. Calcular o Valor Base da Regra Principal
            BEGIN TRY
                SET @SQL_Dynamic = N'SELECT @ValorBase_OUT = ISNULL((' + @FormulaValorBase_Current + N'), 0);';
                SET @Parametros_Definition = N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @ValorBase_OUT DECIMAL(18,2) OUTPUT';
                EXEC sp_executesql @SQL_Dynamic, @Parametros_Definition, @P_PeriodoID, @P_EmpresaID, @ValorBaseCalculado_Result OUTPUT;
            END TRY
            BEGIN CATCH
                SET @StatusExecucaoAtual = 'ERRO_FORMULA_BASE_SQL';
                SET @LogMensagem = CONCAT('Falha ao avaliar FormulaValorBase SQL: ', @FormulaValorBase_Current, '. Erro: ', ERROR_MESSAGE());
                THROW;
            END CATCH

            IF @ValorBaseCalculado_Result = 0
            BEGIN
                SET @StatusExecucaoAtual = 'INFO_VALOR_BASE_ZERO';
                SET @LogMensagem = 'Valor Base calculado é ZERO. Nenhuma partida gerada.';
                PRINT CONCAT(@DataHoraAtual, ' - INFO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                INSERT INTO dbo.LogExecucaoRegras (ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, DescricaoRegraProcessada, CondicaoExecucaoDaRegra, CondicaoSatisfeita, FormulaValorBaseDaRegra, ValorBaseCalculado, StatusExecucao, MensagemDetalhada, Simulacao)
                VALUES (@ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @CondicaoExecucao_Current_Text, @CondicaoSatisfeita_Result, @FormulaValorBase_Current, @ValorBaseCalculado_Result, @StatusExecucaoAtual, @LogMensagem, @P_Simulacao);
                FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text;
                CONTINUE;
            END

            -- 3. Processar Partidas (Débitos e Créditos)
            DECLARE @PartidasDefinidas BIT = 0;
            DECLARE CursorPartidas CURSOR LOCAL FAST_FORWARD FOR
                SELECT TipoPartida, ContaContabil, PercentualSobreValorBase, HistoricoPadraoSugerido
                FROM RegrasCalculoPartidas WHERE RegraID = @RegraID_Current;
            OPEN CursorPartidas;
            FETCH NEXT FROM CursorPartidas INTO @Partida_TipoPartida, @Partida_ContaContabil, @Partida_Percentual, @Partida_HistoricoSugerido;

            IF @@FETCH_STATUS = 0 SET @PartidasDefinidas = 1;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ValorPartidaCalculado = ROUND(@ValorBaseCalculado_Result * (@Partida_Percentual / 100.00), 2);
                DECLARE @HistoricoFinalPartida NVARCHAR(500) = ISNULL(@Partida_HistoricoSugerido, @DescricaoRegra_Current);
                
                IF NOT EXISTS (SELECT 1 FROM PlanoContas pc WHERE pc.ContaID = @Partida_ContaContabil AND pc.EmpresaID = @P_EmpresaID)
                BEGIN
                    SET @StatusExecucaoAtual = 'ERRO_CONTA_INVALIDA';
                    SET @LogMensagem = CONCAT('Partida para conta ', @Partida_ContaContabil, ' inválida (não existe no Plano de Contas para a empresa).');
                    THROW;
                END

                PRINT CONCAT(@DataHoraAtual, '   - Partida Regra ID ', @RegraID_Current,': ', @Partida_TipoPartida, ', Cta: ', @Partida_ContaContabil, ', Valor: ', FORMAT(@ValorPartidaCalculado, 'N', 'pt-BR'));

                IF @P_Simulacao = 0
                BEGIN
                    INSERT INTO LancamentosContabeis (DataLancamento, PeriodoID, EmpresaID, RegraID, NumeroLote, ContaContabil, Historico, ValorDebito, ValorCredito)
                    VALUES (GETDATE(), @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @NumeroLoteAtual, @Partida_ContaContabil, @HistoricoFinalPartida,
                            IIF(@Partida_TipoPartida = 'D', @ValorPartidaCalculado, 0),
                            IIF(@Partida_TipoPartida = 'C', @ValorPartidaCalculado, 0));
                END
                IF @Partida_TipoPartida = 'D' SET @TotalDebitosLote_Regra = @TotalDebitosLote_Regra + @ValorPartidaCalculado;
                IF @Partida_TipoPartida = 'C' SET @TotalCreditosLote_Regra = @TotalCreditosLote_Regra + @ValorPartidaCalculado;
                FETCH NEXT FROM CursorPartidas INTO @Partida_TipoPartida, @Partida_ContaContabil, @Partida_Percentual, @Partida_HistoricoSugerido;
            END
            CLOSE CursorPartidas; DEALLOCATE CursorPartidas;

            IF @PartidasDefinidas = 0
            BEGIN
                SET @StatusExecucaoAtual = 'FALHA_SEM_PARTIDAS';
                SET @LogMensagem = 'Nenhuma partida (D/C) definida para a regra.';
                PRINT CONCAT(@DataHoraAtual, ' - AVISO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                INSERT INTO dbo.LogExecucaoRegras (ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, DescricaoRegraProcessada, CondicaoExecucaoDaRegra, CondicaoSatisfeita, FormulaValorBaseDaRegra, ValorBaseCalculado, StatusExecucao, MensagemDetalhada, Simulacao)
                VALUES (@ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @CondicaoExecucao_Current_Text, @CondicaoSatisfeita_Result, @FormulaValorBase_Current, @ValorBaseCalculado_Result, @StatusExecucaoAtual, @LogMensagem, @P_Simulacao);
                FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text;
                CONTINUE;
            END

            IF ROUND(@TotalDebitosLote_Regra,2) <> ROUND(@TotalCreditosLote_Regra,2)
            BEGIN
                SET @StatusExecucaoAtual = 'ERRO_PARTIDAS_NAO_BATEM';
                SET @LogMensagem = CONCAT('Desbalanceamento D/C. Débitos: ', FORMAT(@TotalDebitosLote_Regra, 'N', 'pt-BR'), ' <> Créditos: ', FORMAT(@TotalCreditosLote_Regra, 'N', 'pt-BR'));
                THROW;
            END

            SET @StatusExecucaoAtual = 'SUCESSO';
            SET @LogMensagem = CONCAT('Regra processada com sucesso. Débitos: ', FORMAT(@TotalDebitosLote_Regra, 'N', 'pt-BR'), ', Créditos: ', FORMAT(@TotalCreditosLote_Regra, 'N', 'pt-BR'));
            PRINT CONCAT(@DataHoraAtual, ' - SUCESSO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
            IF @P_Simulacao = 0 COMMIT TRANSACTION RegraExecucao;

        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
            SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
            IF @StatusExecucaoAtual IS NULL SET @StatusExecucaoAtual = 'ERRO_GERAL_PROCESSAMENTO'; -- Se o status não foi definido antes do THROW
            IF @LogMensagem IS NULL SET @LogMensagem = ERROR_MESSAGE(); ELSE SET @LogMensagem = CONCAT(@LogMensagem, ' | Erro SQL: ', ERROR_MESSAGE());

            PRINT CONCAT(@DataHoraAtual, ' - ERRO CRÍTICO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, '). Status: ',@StatusExecucaoAtual, '. Mensagem: ', @LogMensagem);
            IF CURSOR_STATUS('local', 'CursorPartidas') >= 0 CLOSE CursorPartidas;
            IF CURSOR_STATUS('local', 'CursorPartidas') >= -1 DEALLOCATE CursorPartidas;
        END CATCH

        -- Registrar o resultado final da tentativa de processamento da regra no Log
        INSERT INTO dbo.LogExecucaoRegras (
            ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, DescricaoRegraProcessada,
            CondicaoExecucaoDaRegra, CondicaoSatisfeita, FormulaValorBaseDaRegra, ValorBaseCalculado,
            TotalDebitosGerados, TotalCreditosGerados, StatusExecucao, MensagemDetalhada, Simulacao
        ) VALUES (
            @ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current,
            @CondicaoExecucao_Current_Text, @CondicaoSatisfeita_Result, @FormulaValorBase_Current, @ValorBaseCalculado_Result,
            @TotalDebitosLote_Regra, @TotalCreditosLote_Regra, @StatusExecucaoAtual, @LogMensagem, @P_Simulacao
        );

        FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text;
    END
    CLOSE CursorRegrasCabecalho; DEALLOCATE CursorRegrasCabecalho;

    PRINT CONCAT(CONVERT(VARCHAR, SYSDATETIME(), 121), ' - INFO: Processamento (Partidas Dobradas) concluído (RunID: ', CAST(@ExecutionRunID AS VARCHAR(36)) ,'). Empresa: ', @P_EmpresaID, ', Período: ', @P_PeriodoID, IIF(@P_Simulacao=1, ' (SIMULAÇÃO FINALIZADA)', ' (EXECUÇÃO FINALIZADA)'));
    SET NOCOUNT OFF;
END
GO
