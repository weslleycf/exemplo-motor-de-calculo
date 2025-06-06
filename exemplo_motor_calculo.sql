/*
====================================================================================================
SCRIPT SQL COMPILADO - SISTEMA DE CÁLCULO CONTÁBIL DINÂMICO
====================================================================================================
Este script contém a criação e alteração de tabelas, tipos e stored procedures
para o sistema de cálculo contábil dinâmico, incluindo versionamento, partidas
dobradas, log de auditoria e sistema de validação.

Ordem de Execução:
1. Tabelas de Suporte (PlanoContas, LancamentosContabeis)
2. Tabelas de Regras com Versionamento (RegrasCalculoContabil, RegrasCalculoPartidas)
3. Tabelas de Log (LogExecucaoRegras, LogAprovacaoRegras)
4. Tabelas de Validação (RegrasValidacao, LogValidacoesExecutadas)
5. Stored Procedures (Execução Principal, Teste Unitário, Execução de Validações)
====================================================================================================
*/

USE SEU_BANCO_DE_DADOS; -- <<<<<< ALTERE PARA O NOME DO SEU BANCO DE DADOS AQUI
GO

PRINT 'Iniciando a criação/atualização dos objetos do banco de dados...';
GO

----------------------------------------------------------------------------------------------------
-- 1. TABELAS DE SUPORTE
----------------------------------------------------------------------------------------------------

-- Tabela PlanoContas (Exemplo)
PRINT 'Criando Tabela PlanoContas...';
IF OBJECT_ID('dbo.PlanoContas', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PlanoContas (
        PlanoContasUID INT IDENTITY(1,1) PRIMARY KEY,
        EmpresaID VARCHAR(50) NOT NULL,
        ContaID VARCHAR(50) NOT NULL,
        DescricaoConta NVARCHAR(255) NOT NULL,
        Natureza CHAR(1) NOT NULL CHECK (Natureza IN ('D', 'C')), -- D=Devedora, C=Credora
        CONSTRAINT UQ_PlanoContas_EmpresaConta UNIQUE (EmpresaID, ContaID)
    );
    PRINT 'Tabela PlanoContas criada.';
END
ELSE
BEGIN
    PRINT 'Tabela PlanoContas já existe.';
END
GO

-- Tabela de Lançamentos Contábeis (Exemplo)
PRINT 'Criando Tabela LancamentosContabeis...';
IF OBJECT_ID('dbo.LancamentosContabeis', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LancamentosContabeis (
        LancamentoID BIGINT IDENTITY(1,1) PRIMARY KEY,
        DataLancamento DATETIME NOT NULL,
        PeriodoID INT NOT NULL,
        EmpresaID VARCHAR(50) NOT NULL,
        RegraID INT NULL,
        NumeroLote INT NULL,
        ContaContabil VARCHAR(50) NOT NULL,
        Historico NVARCHAR(500) NULL,
        ValorDebito DECIMAL(18,2) NOT NULL DEFAULT 0,
        ValorCredito DECIMAL(18,2) NOT NULL DEFAULT 0,
        -- FK para RegraID será adicionada após RegrasCalculoContabil ser criada,
        -- para evitar problemas de ordem de criação se este script for reexecutado.
        CONSTRAINT CK_Lancamentos_DebitoCredito CHECK (ValorDebito >= 0 AND ValorCredito >= 0 AND (ValorDebito > 0 OR ValorCredito > 0) AND (ValorDebito = 0 OR ValorCredito = 0))
    );
    CREATE INDEX IX_LancamentosContabeis_PeriodoEmpresa ON dbo.LancamentosContabeis(PeriodoID, EmpresaID);
    CREATE INDEX IX_LancamentosContabeis_NumeroLote ON dbo.LancamentosContabeis(NumeroLote) WHERE NumeroLote IS NOT NULL;
    PRINT 'Tabela LancamentosContabeis criada.';
END
ELSE
BEGIN
    PRINT 'Tabela LancamentosContabeis já existe.';
END
GO

----------------------------------------------------------------------------------------------------
-- 2. TABELAS DE REGRAS COM VERSIONAMENTO (TEMPORAL TABLES)
----------------------------------------------------------------------------------------------------

PRINT 'Configurando Tabela RegrasCalculoContabil com versionamento temporal...';
-- Dropar dependências e a tabela de histórico primeiro, se existirem, para recriação limpa
IF OBJECT_ID('dbo.RegrasCalculoPartidas', 'U') IS NOT NULL AND EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_RCP_Regra' AND parent_object_id = OBJECT_ID('dbo.RegrasCalculoPartidas'))
BEGIN
    ALTER TABLE dbo.RegrasCalculoPartidas DROP CONSTRAINT FK_RCP_Regra;
    PRINT 'FK FK_RCP_Regra removida de RegrasCalculoPartidas.';
END
GO

IF OBJECT_ID('dbo.LogAprovacaoRegras', 'U') IS NOT NULL AND EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_LogAprovacao_Regra' AND parent_object_id = OBJECT_ID('dbo.LogAprovacaoRegras'))
BEGIN
    ALTER TABLE dbo.LogAprovacaoRegras DROP CONSTRAINT FK_LogAprovacao_Regra;
    PRINT 'FK FK_LogAprovacao_Regra removida de LogAprovacaoRegras.';
END
GO

IF OBJECT_ID('dbo.LancamentosContabeis', 'U') IS NOT NULL AND EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Lancamentos_RegraRCC' AND parent_object_id = OBJECT_ID('dbo.LancamentosContabeis'))
BEGIN
    ALTER TABLE dbo.LancamentosContabeis DROP CONSTRAINT FK_Lancamentos_RegraRCC;
    PRINT 'FK FK_Lancamentos_RegraRCC removida de LancamentosContabeis.';
END
GO

IF OBJECT_ID('dbo.RegrasCalculoContabil_History', 'U') IS NOT NULL DROP TABLE dbo.RegrasCalculoContabil_History;
IF OBJECT_ID('dbo.RegrasCalculoContabil', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RegrasCalculoContabil' AND temporal_type = 2) -- 2 = SYSTEM_VERSIONED_TEMPORAL_TABLE
        ALTER TABLE dbo.RegrasCalculoContabil SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE dbo.RegrasCalculoContabil;
    PRINT 'Tabela RegrasCalculoContabil existente removida para recriação com versionamento.';
END
GO

CREATE TABLE dbo.RegrasCalculoContabil (
    RegraID INT IDENTITY(1,1) NOT NULL,
    RegraConceito VARCHAR(100) NOT NULL,
    DescricaoRegra NVARCHAR(255) NOT NULL,
    EmpresaEspecificaID VARCHAR(50) NULL,
    FormulaValorBase NVARCHAR(MAX) NOT NULL,
    CondicaoExecucao NVARCHAR(MAX) NULL,
    OrdemExecucao INT NOT NULL DEFAULT 0,
    Ativa BIT NOT NULL DEFAULT 1,
    StatusAprovacao VARCHAR(20) NOT NULL DEFAULT 'PENDENTE' CHECK (StatusAprovacao IN ('PENDENTE', 'APROVADA', 'REJEITADA', 'EM_REVISAO')),
    AprovadoPor NVARCHAR(100) NULL,
    DataAprovacao DATETIME2 NULL,
    SolicitadoPor NVARCHAR(100) NULL,
    DataSolicitacao DATETIME2 NULL DEFAULT GETDATE(),
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
    CONSTRAINT PK_RegrasCalculoContabil PRIMARY KEY (RegraID)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.RegrasCalculoContabil_History));
PRINT 'Tabela RegrasCalculoContabil criada com versionamento temporal.';
GO
CREATE INDEX IX_RCC_ConceitoEmpresaAtiva ON dbo.RegrasCalculoContabil(RegraConceito, EmpresaEspecificaID, Ativa, StatusAprovacao);
CREATE UNIQUE INDEX UQ_RCC_ConceitoPadrao ON dbo.RegrasCalculoContabil(RegraConceito) WHERE EmpresaEspecificaID IS NULL;
CREATE UNIQUE INDEX UQ_RCC_ConceitoEmpresa ON dbo.RegrasCalculoContabil(RegraConceito, EmpresaEspecificaID) WHERE EmpresaEspecificaID IS NOT NULL;
PRINT 'Índices para RegrasCalculoContabil criados.';
GO

PRINT 'Configurando Tabela RegrasCalculoPartidas com versionamento temporal...';
IF OBJECT_ID('dbo.RegrasCalculoPartidas_History', 'U') IS NOT NULL DROP TABLE dbo.RegrasCalculoPartidas_History;
IF OBJECT_ID('dbo.RegrasCalculoPartidas', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RegrasCalculoPartidas' AND temporal_type = 2)
        ALTER TABLE dbo.RegrasCalculoPartidas SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE dbo.RegrasCalculoPartidas;
    PRINT 'Tabela RegrasCalculoPartidas existente removida para recriação com versionamento.';
END
GO
CREATE TABLE dbo.RegrasCalculoPartidas (
    PartidaID INT IDENTITY(1,1) NOT NULL,
    RegraID INT NOT NULL,
    TipoPartida CHAR(1) NOT NULL CHECK (TipoPartida IN ('D', 'C')),
    ContaContabil VARCHAR(50) NOT NULL,
    PercentualSobreValorBase DECIMAL(18, 4) NOT NULL DEFAULT 100.00,
    HistoricoPadraoSugerido NVARCHAR(255) NULL,
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
    CONSTRAINT PK_RegrasCalculoPartidas PRIMARY KEY (PartidaID),
    CONSTRAINT FK_RCP_Regra FOREIGN KEY (RegraID) REFERENCES dbo.RegrasCalculoContabil(RegraID) ON DELETE CASCADE
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.RegrasCalculoPartidas_History));
PRINT 'Tabela RegrasCalculoPartidas criada com versionamento temporal.';
GO
CREATE INDEX IX_RCP_RegraID ON dbo.RegrasCalculoPartidas(RegraID);
PRINT 'Índice para RegrasCalculoPartidas criado.';
GO

-- Adicionando FK de LancamentosContabeis para RegrasCalculoContabil
PRINT 'Adicionando FK de LancamentosContabeis para RegrasCalculoContabil...';
IF OBJECT_ID('dbo.LancamentosContabeis', 'U') IS NOT NULL AND OBJECT_ID('dbo.RegrasCalculoContabil', 'U') IS NOT NULL
    AND NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Lancamentos_RegraRCC' AND parent_object_id = OBJECT_ID('dbo.LancamentosContabeis'))
BEGIN
    ALTER TABLE dbo.LancamentosContabeis
    ADD CONSTRAINT FK_Lancamentos_RegraRCC FOREIGN KEY (RegraID) REFERENCES dbo.RegrasCalculoContabil(RegraID);
    PRINT 'FK FK_Lancamentos_RegraRCC adicionada.';
END
GO


----------------------------------------------------------------------------------------------------
-- 3. TABELAS DE LOG
----------------------------------------------------------------------------------------------------

PRINT 'Criando Tabela LogExecucaoRegras...';
IF OBJECT_ID('dbo.LogExecucaoRegras', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LogExecucaoRegras (
        LogID BIGINT IDENTITY(1,1) PRIMARY KEY,
        ExecutionRunID UNIQUEIDENTIFIER NOT NULL,
        NumeroLote INT NULL,
        DataProcessamento DATETIME2 NOT NULL DEFAULT GETDATE(),
        PeriodoID INT NOT NULL,
        EmpresaID VARCHAR(50) NOT NULL,
        RegraID INT NOT NULL,
        RegraConceito VARCHAR(100) NOT NULL,
        RegraSysStartTime DATETIME2 NULL, -- Para versionamento da regra
        DescricaoRegraProcessada NVARCHAR(255) NULL,
        CondicaoExecucaoDaRegra NVARCHAR(MAX) NULL,
        CondicaoSatisfeita BIT NULL,
        FormulaValorBaseDaRegra NVARCHAR(MAX) NULL,
        ValorBaseCalculado DECIMAL(18,2) NULL,
        TotalDebitosGerados DECIMAL(18,2) NULL,
        TotalCreditosGerados DECIMAL(18,2) NULL,
        StatusExecucao VARCHAR(50) NOT NULL,
        MensagemDetalhada NVARCHAR(MAX) NULL,
        Simulacao BIT NOT NULL
    );
    CREATE INDEX IX_LogExecucaoRegras_RunID ON dbo.LogExecucaoRegras(ExecutionRunID);
    CREATE INDEX IX_LogExecucaoRegras_RegraPeriodoEmpresa ON dbo.LogExecucaoRegras(RegraID, PeriodoID, EmpresaID, DataProcessamento);
    CREATE INDEX IX_LogExecucaoRegras_StatusData ON dbo.LogExecucaoRegras(StatusExecucao, DataProcessamento);
    PRINT 'Tabela LogExecucaoRegras criada.';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'RegraSysStartTime' AND Object_ID = Object_ID(N'dbo.LogExecucaoRegras'))
    BEGIN
        ALTER TABLE dbo.LogExecucaoRegras ADD RegraSysStartTime DATETIME2 NULL;
        PRINT 'Coluna RegraSysStartTime adicionada a LogExecucaoRegras existente.';
    END
    ELSE
    BEGIN
         PRINT 'Tabela LogExecucaoRegras já existe.';
    END
END
GO

PRINT 'Criando Tabela LogAprovacaoRegras...';
IF OBJECT_ID('dbo.LogAprovacaoRegras', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LogAprovacaoRegras (
        LogAprovacaoID INT IDENTITY(1,1) PRIMARY KEY,
        RegraID INT NOT NULL,
        RegraSysStartTime DATETIME2 NULL, -- Identifica a versão da regra à qual a ação de aprovação se refere
        DataAcao DATETIME2 NOT NULL DEFAULT GETDATE(),
        UsuarioAcao NVARCHAR(100) NOT NULL,
        StatusAnterior VARCHAR(20) NULL,
        StatusNovo VARCHAR(20) NOT NULL,
        Comentarios NVARCHAR(MAX) NULL,
        CONSTRAINT FK_LogAprovacao_Regra FOREIGN KEY (RegraID) REFERENCES dbo.RegrasCalculoContabil(RegraID)
        -- Se RegraSysStartTime for usado na FK, a FK seria para uma tabela de histórico ou um RegraVersaoID.
        -- Mantendo simples com FK para RegraID da tabela principal.
    );
    PRINT 'Tabela LogAprovacaoRegras criada.';
END
ELSE
BEGIN
    PRINT 'Tabela LogAprovacaoRegras já existe.';
END
GO


----------------------------------------------------------------------------------------------------
-- 4. TABELAS DE VALIDAÇÃO
----------------------------------------------------------------------------------------------------

PRINT 'Criando Tabela RegrasValidacao...';
IF OBJECT_ID('dbo.RegrasValidacao', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RegrasValidacao (
        ValidacaoID INT IDENTITY(1,1) PRIMARY KEY,
        ValidacaoConceito VARCHAR(100) NOT NULL,
        DescricaoValidacao NVARCHAR(255) NOT NULL,
        EmpresaEspecificaID VARCHAR(50) NULL,
        FormulaValidacaoSQL NVARCHAR(MAX) NOT NULL,
        MensagemFalhaTemplate NVARCHAR(500) NOT NULL,
        NivelSeveridade VARCHAR(20) NOT NULL DEFAULT 'AVISO' CHECK (NivelSeveridade IN ('AVISO', 'ERRO')),
        Ativa BIT NOT NULL DEFAULT 1,
        OrdemExecucao INT NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX UQ_RegrasValidacao_ConceitoEmpresa ON dbo.RegrasValidacao(ValidacaoConceito, EmpresaEspecificaID) WHERE Ativa = 1;
    PRINT 'Tabela RegrasValidacao criada.';
END
ELSE
BEGIN
    PRINT 'Tabela RegrasValidacao já existe.';
END
GO

PRINT 'Criando Tabela LogValidacoesExecutadas...';
IF OBJECT_ID('dbo.LogValidacoesExecutadas', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LogValidacoesExecutadas (
        LogValidacaoID BIGINT IDENTITY(1,1) PRIMARY KEY,
        ExecutionRunID UNIQUEIDENTIFIER NOT NULL,
        NumeroLote INT NULL,
        ValidacaoID INT NOT NULL,
        DataValidacao DATETIME2 NOT NULL DEFAULT GETDATE(),
        PeriodoID INT NOT NULL,
        EmpresaID VARCHAR(50) NOT NULL,
        StatusValidacao VARCHAR(20) NOT NULL CHECK (StatusValidacao IN ('OK', 'FALHA_AVISO', 'FALHA_ERRO', 'ERRO_VALIDACAO_SQL')),
        ResultadoDetalhado NVARCHAR(MAX) NULL,
        Simulacao BIT NOT NULL,
        CONSTRAINT FK_LogValidacoes_RegraValidacao FOREIGN KEY (ValidacaoID) REFERENCES dbo.RegrasValidacao(ValidacaoID)
    );
    CREATE INDEX IX_LogValidacoes_RunID ON dbo.LogValidacoesExecutadas(ExecutionRunID);
    CREATE INDEX IX_LogValidacoes_ValidacaoPeriodoEmpresa ON dbo.LogValidacoesExecutadas(ValidacaoID, PeriodoID, EmpresaID, DataValidacao);
    PRINT 'Tabela LogValidacoesExecutadas criada.';
END
ELSE
BEGIN
    PRINT 'Tabela LogValidacoesExecutadas já existe.';
END
GO


----------------------------------------------------------------------------------------------------
-- 5. STORED PROCEDURES
----------------------------------------------------------------------------------------------------

PRINT 'Criando/Alterando Stored Procedure sp_ExecutarRegrasContabeisComPartidasDobradas...';
GO
CREATE OR ALTER PROCEDURE dbo.sp_ExecutarRegrasContabeisComPartidasDobradas
    @P_PeriodoID INT,
    @P_EmpresaID VARCHAR(50),
    @P_Simulacao BIT = 0,
    @P_ParametrosGlobaisJSON NVARCHAR(MAX) = NULL -- Item 7
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LogMensagem NVARCHAR(MAX);
    DECLARE @DataHoraAtual VARCHAR(23);
    DECLARE @NumeroLoteAtual INT;
    DECLARE @ExecutionRunID UNIQUEIDENTIFIER = NEWID();

    -- Parâmetros Globais (Item 7) - Exemplo de como poderiam ser extraídos
    DECLARE @GV_TaxaCambio DECIMAL(18,6), @GV_IndiceXPTO DECIMAL(18,6); -- Adicione quantos precisar
    IF ISJSON(@P_ParametrosGlobaisJSON) = 1
    BEGIN
        SELECT
            @GV_TaxaCambio = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.TaxaCambio'),
            @GV_IndiceXPTO = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.IndiceXPTO');
        -- Se algum parâmetro global for NULL aqui, ele permanecerá NULL.
        -- As fórmulas que os usam devem estar preparadas para isso (ex: com ISNULL(@GV_TaxaCambio, taxa_padrao_fixa))
    END


    IF @P_Simulacao = 0
    BEGIN
        SELECT @NumeroLoteAtual = ISNULL(MAX(NumeroLote), 0) + 1 FROM dbo.LancamentosContabeis WITH (TABLOCKX, HOLDLOCK);
    END
    ELSE
    BEGIN
        SELECT @NumeroLoteAtual = ISNULL(MAX(NumeroLote), 0) + 1 FROM dbo.LancamentosContabeis;
    END

    DECLARE @RegrasCabecalhoParaExecucao TABLE (
        RegraID INT PRIMARY KEY, RegraConceito VARCHAR(100), OrdemExecucao INT,
        DescricaoRegra NVARCHAR(255), FormulaValorBase NVARCHAR(MAX), CondicaoExecucao NVARCHAR(MAX),
        RegraSysStartTime DATETIME2
    );

    WITH RegrasPriorizadas AS (
        SELECT rc.RegraID, rc.RegraConceito, rc.OrdemExecucao, rc.DescricaoRegra,
               rc.FormulaValorBase, rc.CondicaoExecucao, rc.SysStartTime AS RegraSysStartTime,
               ROW_NUMBER() OVER (PARTITION BY rc.RegraConceito ORDER BY CASE WHEN rc.EmpresaEspecificaID = @P_EmpresaID THEN 0 ELSE 1 END ASC) as Prioridade
        FROM dbo.RegrasCalculoContabil rc
        WHERE rc.Ativa = 1 AND rc.StatusAprovacao = 'APROVADA' -- Item 4: Workflow
              AND (rc.EmpresaEspecificaID = @P_EmpresaID OR rc.EmpresaEspecificaID IS NULL)
    )
    INSERT INTO @RegrasCabecalhoParaExecucao
    SELECT RegraID, RegraConceito, OrdemExecucao, DescricaoRegra, FormulaValorBase, CondicaoExecucao, RegraSysStartTime
    FROM RegrasPriorizadas WHERE Prioridade = 1;

    SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Iniciando processamento (RunID: ', CAST(@ExecutionRunID AS VARCHAR(36)) ,'). Empresa: ', @P_EmpresaID, ', Período: ', @P_PeriodoID, ', Lote: ', @NumeroLoteAtual, IIF(@P_Simulacao=1, ' (SIMULAÇÃO)', ''));

    IF NOT EXISTS (SELECT 1 FROM @RegrasCabecalhoParaExecucao)
    BEGIN
        SET @LogMensagem = 'Nenhuma regra aplicável encontrada para os critérios fornecidos.';
        PRINT CONCAT(@DataHoraAtual, ' - INFO: ', @LogMensagem);
        INSERT INTO dbo.LogExecucaoRegras (ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, DescricaoRegraProcessada, StatusExecucao, MensagemDetalhada, Simulacao)
        VALUES (@ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, 0, 'N/A_SETUP', NULL, 'INFO_SEM_REGRAS', @LogMensagem, @P_Simulacao);
        RETURN;
    END

    DECLARE @RegraID_Current INT, @RegraConceito_Current VARCHAR(100), @DescricaoRegra_Current NVARCHAR(255),
            @FormulaValorBase_Current NVARCHAR(MAX), @CondicaoExecucao_Current_Text NVARCHAR(MAX),
            @RegraSysStartTime_Current DATETIME2;
    DECLARE @Partida_TipoPartida CHAR(1), @Partida_ContaContabil VARCHAR(50),
            @Partida_Percentual DECIMAL(18,4), @Partida_HistoricoSugerido NVARCHAR(255);
    DECLARE @SQL_Dynamic NVARCHAR(MAX), @Parametros_Definition NVARCHAR(MAX), -- Aumentado para acomodar mais GVs
            @CondicaoSatisfeita_Result BIT, @ValorBaseCalculado_Result DECIMAL(18,2), @ValorPartidaCalculado DECIMAL(18,2);
    DECLARE @TotalDebitosLote_Regra DECIMAL(18,2), @TotalCreditosLote_Regra DECIMAL(18,2);
    DECLARE @StatusExecucaoAtual VARCHAR(50);

    DECLARE CursorRegrasCabecalho CURSOR LOCAL FAST_FORWARD FOR
        SELECT RegraID, RegraConceito, DescricaoRegra, FormulaValorBase, CondicaoExecucao, RegraSysStartTime
        FROM @RegrasCabecalhoParaExecucao ORDER BY OrdemExecucao, RegraID;

    OPEN CursorRegrasCabecalho;
    FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text, @RegraSysStartTime_Current;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ValorBaseCalculado_Result = NULL; SET @CondicaoSatisfeita_Result = 1;
        SET @TotalDebitosLote_Regra = 0; SET @TotalCreditosLote_Regra = 0;
        SET @StatusExecucaoAtual = NULL; SET @LogMensagem = NULL;
        SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);

        IF @P_Simulacao = 0 BEGIN TRANSACTION RegraExecucao;

        BEGIN TRY
            IF @CondicaoExecucao_Current_Text IS NOT NULL AND LTRIM(RTRIM(@CondicaoExecucao_Current_Text)) <> ''
            BEGIN
                BEGIN TRY
                    SET @SQL_Dynamic = N'SELECT @CondResult_OUT = CASE WHEN (' + @CondicaoExecucao_Current_Text + N') THEN 1 ELSE 0 END;';
                    SET @Parametros_Definition = N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @CondResult_OUT BIT OUTPUT';
                    EXEC sp_executesql @SQL_Dynamic, @Parametros_Definition,
                                       @P_PeriodoID_IN = @P_PeriodoID, @P_EmpresaID_IN = @P_EmpresaID,
                                       @GV_TaxaCambio_IN = @GV_TaxaCambio, @GV_IndiceXPTO_IN = @GV_IndiceXPTO,
                                       @CondResult_OUT = @CondicaoSatisfeita_Result OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @StatusExecucaoAtual = 'ERRO_CONDICAO_SQL'; SET @LogMensagem = CONCAT('Falha SQL CondicaoExecucao: ', ERROR_MESSAGE()); THROW;
                END CATCH
            END

            IF @CondicaoSatisfeita_Result = 0
            BEGIN
                SET @StatusExecucaoAtual = 'FALHA_CONDICAO'; SET @LogMensagem = CONCAT('Condição (', LEFT(ISNULL(@CondicaoExecucao_Current_Text,'N/A'),100), '...) não satisfeita.');
                PRINT CONCAT(@DataHoraAtual, ' - INFO: Regra ID ', @RegraID_Current, ' ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                THROW; -- Pula para o CATCH principal para logar e continuar
            END

            BEGIN TRY
                SET @SQL_Dynamic = N'SELECT @ValorBase_OUT = ISNULL((' + @FormulaValorBase_Current + N'), 0);';
                SET @Parametros_Definition = N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @ValorBase_OUT DECIMAL(18,2) OUTPUT';
                EXEC sp_executesql @SQL_Dynamic, @Parametros_Definition,
                                   @P_PeriodoID_IN = @P_PeriodoID, @P_EmpresaID_IN = @P_EmpresaID,
                                   @GV_TaxaCambio_IN = @GV_TaxaCambio, @GV_IndiceXPTO_IN = @GV_IndiceXPTO,
                                   @ValorBase_OUT = @ValorBaseCalculado_Result OUTPUT;
            END TRY
            BEGIN CATCH
                SET @StatusExecucaoAtual = 'ERRO_FORMULA_BASE_SQL'; SET @LogMensagem = CONCAT('Falha SQL FormulaValorBase: ', ERROR_MESSAGE()); THROW;
            END CATCH

            IF @ValorBaseCalculado_Result = 0
            BEGIN
                SET @StatusExecucaoAtual = 'INFO_VALOR_BASE_ZERO'; SET @LogMensagem = 'Valor Base calculado é ZERO. Nenhuma partida gerada.';
                PRINT CONCAT(@DataHoraAtual, ' - INFO: Regra ID ', @RegraID_Current, ' ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                THROW;
            END

            DECLARE @PartidasDefinidas BIT = 0;
            DECLARE CursorPartidas CURSOR LOCAL FAST_FORWARD FOR
                SELECT TipoPartida, ContaContabil, PercentualSobreValorBase, HistoricoPadraoSugerido
                FROM dbo.RegrasCalculoPartidas WHERE RegraID = @RegraID_Current;
            OPEN CursorPartidas;
            FETCH NEXT FROM CursorPartidas INTO @Partida_TipoPartida, @Partida_ContaContabil, @Partida_Percentual, @Partida_HistoricoSugerido;

            IF @@FETCH_STATUS = 0 SET @PartidasDefinidas = 1;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ValorPartidaCalculado = ROUND(@ValorBaseCalculado_Result * (@Partida_Percentual / 100.00), 2);
                DECLARE @HistoricoFinalPartida NVARCHAR(500) = ISNULL(@Partida_HistoricoSugerido, @DescricaoRegra_Current);
                IF NOT EXISTS (SELECT 1 FROM dbo.PlanoContas pc WHERE pc.ContaID = @Partida_ContaContabil AND pc.EmpresaID = @P_EmpresaID)
                BEGIN
                    SET @StatusExecucaoAtual = 'ERRO_CONTA_INVALIDA'; SET @LogMensagem = CONCAT('Conta Contábil ', @Partida_ContaContabil, ' da partida não encontrada no Plano de Contas para Empresa ', @P_EmpresaID, '.'); THROW;
                END
                PRINT CONCAT(@DataHoraAtual, '   - Partida Regra ID ', @RegraID_Current,': ', @Partida_TipoPartida, ', Cta: ', @Partida_ContaContabil, ', Valor: ', FORMAT(@ValorPartidaCalculado, 'N', 'pt-BR'));
                IF @P_Simulacao = 0
                BEGIN
                    INSERT INTO dbo.LancamentosContabeis (DataLancamento, PeriodoID, EmpresaID, RegraID, NumeroLote, ContaContabil, Historico, ValorDebito, ValorCredito)
                    VALUES (GETDATE(), @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @NumeroLoteAtual, @Partida_ContaContabil, @HistoricoFinalPartida,
                            IIF(@Partida_TipoPartida = 'D', @ValorPartidaCalculado, 0), IIF(@Partida_TipoPartida = 'C', @ValorPartidaCalculado, 0));
                END
                IF @Partida_TipoPartida = 'D' SET @TotalDebitosLote_Regra = @TotalDebitosLote_Regra + @ValorPartidaCalculado;
                IF @Partida_TipoPartida = 'C' SET @TotalCreditosLote_Regra = @TotalCreditosLote_Regra + @ValorPartidaCalculado;
                FETCH NEXT FROM CursorPartidas INTO @Partida_TipoPartida, @Partida_ContaContabil, @Partida_Percentual, @Partida_HistoricoSugerido;
            END
            CLOSE CursorPartidas; DEALLOCATE CursorPartidas;

            IF @PartidasDefinidas = 0
            BEGIN
                SET @StatusExecucaoAtual = 'FALHA_SEM_PARTIDAS'; SET @LogMensagem = 'Nenhuma partida (D/C) definida para a regra.';
                PRINT CONCAT(@DataHoraAtual, ' - AVISO: Regra ID ', @RegraID_Current, ' ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                THROW;
            END

            IF ROUND(@TotalDebitosLote_Regra,2) <> ROUND(@TotalCreditosLote_Regra,2)
            BEGIN
                SET @StatusExecucaoAtual = 'ERRO_PARTIDAS_NAO_BATEM'; SET @LogMensagem = CONCAT('Desbalanceamento D/C. Débitos: ', FORMAT(@TotalDebitosLote_Regra, 'N', 'pt-BR'), ' <> Créditos: ', FORMAT(@TotalCreditosLote_Regra, 'N', 'pt-BR'));
                THROW;
            END

            SET @StatusExecucaoAtual = 'SUCESSO';
            SET @LogMensagem = CONCAT('Regra processada. Débitos: ', FORMAT(@TotalDebitosLote_Regra, 'N', 'pt-BR'), ', Créditos: ', FORMAT(@TotalCreditosLote_Regra, 'N', 'pt-BR'));
            PRINT CONCAT(@DataHoraAtual, ' - SUCESSO: Regra ID ', @RegraID_Current, ' ', @LogMensagem);
            IF @P_Simulacao = 0 COMMIT TRANSACTION RegraExecucao;

        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
            SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
            IF @StatusExecucaoAtual IS NULL SET @StatusExecucaoAtual = 'ERRO_GERAL_PROCESSAMENTO';
            IF @LogMensagem IS NULL SET @LogMensagem = ERROR_MESSAGE(); ELSE SET @LogMensagem = CONCAT(@LogMensagem, ' | Erro SQL: ', ERROR_MESSAGE(), ' Linha: ', ERROR_LINE());
            PRINT CONCAT(@DataHoraAtual, ' - ERRO CRÍTICO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, '). Status: ',@StatusExecucaoAtual, '. Mensagem: ', @LogMensagem);
            IF CURSOR_STATUS('local', 'CursorPartidas') >= 0 CLOSE CursorPartidas; IF CURSOR_STATUS('local', 'CursorPartidas') >= -1 DEALLOCATE CursorPartidas;
        END CATCH

        INSERT INTO dbo.LogExecucaoRegras (
            ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, RegraSysStartTime, DescricaoRegraProcessada,
            CondicaoExecucaoDaRegra, CondicaoSatisfeita, FormulaValorBaseDaRegra, ValorBaseCalculado,
            TotalDebitosGerados, TotalCreditosGerados, StatusExecucao, MensagemDetalhada, Simulacao
        ) VALUES (
            @ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @RegraConceito_Current, @RegraSysStartTime_Current, @DescricaoRegra_Current,
            @CondicaoExecucao_Current_Text, @CondicaoSatisfeita_Result, @FormulaValorBase_Current, @ValorBaseCalculado_Result,
            @TotalDebitosLote_Regra, @TotalCreditosLote_Regra, @StatusExecucaoAtual, @LogMensagem, @P_Simulacao
        );
        FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text, @RegraSysStartTime_Current;
    END
    CLOSE CursorRegrasCabecalho; DEALLOCATE CursorRegrasCabecalho;
    PRINT CONCAT(CONVERT(VARCHAR, SYSDATETIME(), 121), ' - INFO: Processamento (Partidas Dobradas) concluído (RunID: ', CAST(@ExecutionRunID AS VARCHAR(36)) ,').');
    SET NOCOUNT OFF;
END
GO

PRINT 'Criando/Alterando Stored Procedure sp_TestarRegraCalculoDetalhada...';
GO
CREATE OR ALTER PROCEDURE dbo.sp_TestarRegraCalculoDetalhada
    @P_RegraID_ParaTeste INT,
    @P_PeriodoID INT,
    @P_EmpresaID VARCHAR(50),
    @P_ParametrosGlobaisJSON NVARCHAR(MAX) = NULL, -- Adicionado para consistência
    @P_ValoresMockJSON NVARCHAR(MAX) = NULL -- Mantido, mas a implementação do mock é complexa
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ResultadoTeste TABLE ( Fase VARCHAR(100), Status VARCHAR(20), Detalhes NVARCHAR(MAX), ValorCalculado DECIMAL(18,2) NULL, PartidasGeradasXML XML NULL );
    DECLARE @RegraConceito_Test VARCHAR(100), @DescricaoRegra_Test NVARCHAR(255),
            @FormulaValorBase_Test NVARCHAR(MAX), @CondicaoExecucao_Test NVARCHAR(MAX);
    DECLARE @GV_TaxaCambio DECIMAL(18,6), @GV_IndiceXPTO DECIMAL(18,6); -- Exemplo GVs

    IF ISJSON(@P_ParametrosGlobaisJSON) = 1
    BEGIN
        SELECT @GV_TaxaCambio = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.TaxaCambio'), @GV_IndiceXPTO = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.IndiceXPTO');
    END

    SELECT TOP 1 @RegraConceito_Test = rc.RegraConceito, @DescricaoRegra_Test = rc.DescricaoRegra,
                   @FormulaValorBase_Test = rc.FormulaValorBase, @CondicaoExecucao_Test = rc.CondicaoExecucao
    FROM dbo.RegrasCalculoContabil rc WHERE rc.RegraID = @P_RegraID_ParaTeste AND rc.Ativa = 1 AND rc.StatusAprovacao = 'APROVADA';

    IF @FormulaValorBase_Test IS NULL
    BEGIN
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('SETUP_REGRA', 'ERRO', CONCAT('RegraID ', @P_RegraID_ParaTeste, ' não encontrada, inativa ou não aprovada.'));
        SELECT Fase, Status, Detalhes FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra'); RETURN;
    END

    PRINT '--- TESTE DE REGRA ID: ' + CAST(@P_RegraID_ParaTeste AS VARCHAR) + ' ---';
    PRINT 'Descrição: ' + @DescricaoRegra_Test;

    DECLARE @CondicaoSatisfeita_Test BIT = 1;
    IF @CondicaoExecucao_Test IS NOT NULL AND LTRIM(RTRIM(@CondicaoExecucao_Test)) <> ''
    BEGIN
        BEGIN TRY
            DECLARE @SQLCond NVARCHAR(MAX) = N'SELECT @CondResult_OUT = CASE WHEN (' + @CondicaoExecucao_Test + N') THEN 1 ELSE 0 END;';
            EXEC sp_executesql @SQLCond, N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @CondResult_OUT BIT OUTPUT',
                               @P_PeriodoID, @P_EmpresaID, @GV_TaxaCambio, @GV_IndiceXPTO, @CondicaoSatisfeita_Test OUTPUT;
            INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('CONDICAO_EXECUCAO', IIF(@CondicaoSatisfeita_Test=1, 'OK', 'NAO_SATISFEITA'), @CondicaoExecucao_Test);
            PRINT 'Condição: ' + @CondicaoExecucao_Test + ' -> Satisfeita: ' + IIF(@CondicaoSatisfeita_Test=1, 'SIM', 'NÃO');
        END TRY
        BEGIN CATCH
            INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('CONDICAO_EXECUCAO', 'ERRO_SQL', ERROR_MESSAGE());
            PRINT 'ERRO Condição: ' + ERROR_MESSAGE();
            SELECT Fase, Status, Detalhes FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra'); RETURN;
        END CATCH
    END ELSE BEGIN
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('CONDICAO_EXECUCAO', 'N/A', 'Sem condição.');
        PRINT 'Condição: N/A';
    END
    IF @CondicaoSatisfeita_Test = 0 BEGIN SELECT Fase, Status, Detalhes FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra'); RETURN; END

    DECLARE @ValorBaseCalculado_Test DECIMAL(18,2);
    BEGIN TRY
        DECLARE @SQLValorBase NVARCHAR(MAX) = N'SELECT @ValorBase_OUT = ISNULL((' + @FormulaValorBase_Test + N'), 0);';
        EXEC sp_executesql @SQLValorBase, N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @ValorBase_OUT DECIMAL(18,2) OUTPUT',
                           @P_PeriodoID, @P_EmpresaID, @GV_TaxaCambio, @GV_IndiceXPTO, @ValorBaseCalculado_Test OUTPUT;
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes, ValorCalculado) VALUES ('FORMULA_VALOR_BASE', 'OK', @FormulaValorBase_Test, @ValorBaseCalculado_Test);
        PRINT 'Fórmula Valor Base: ' + @FormulaValorBase_Test + ' -> Valor: ' + FORMAT(@ValorBaseCalculado_Test, 'N', 'pt-BR');
    END TRY
    BEGIN CATCH
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('FORMULA_VALOR_BASE', 'ERRO_SQL', ERROR_MESSAGE());
        PRINT 'ERRO Fórmula Valor Base: ' + ERROR_MESSAGE();
        SELECT Fase, Status, Detalhes FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra'); RETURN;
    END

    DECLARE @TotalDebitos_Test DECIMAL(18,2) = 0, @TotalCreditos_Test DECIMAL(18,2) = 0;
    DECLARE @PartidasXML XML;
    SELECT @PartidasXML = (
        SELECT rp.TipoPartida AS "@Tipo", rp.ContaContabil AS "@Conta", rp.PercentualSobreValorBase AS "@Percentual",
               ROUND(@ValorBaseCalculado_Test * (rp.PercentualSobreValorBase / 100.00), 2) AS "@ValorCalculadoPartida",
               ISNULL(rp.HistoricoPadraoSugerido, @DescricaoRegra_Test) AS "Historico"
        FROM dbo.RegrasCalculoPartidas rp WHERE rp.RegraID = @P_RegraID_ParaTeste
        FOR XML PATH('Partida'), ROOT('Partidas')
    );
    IF @PartidasXML IS NOT NULL
    BEGIN
        SELECT @TotalDebitos_Test = ISNULL(SUM(CASE WHEN T.c.value('@Tipo', 'CHAR(1)') = 'D' THEN T.c.value('@ValorCalculadoPartida', 'DECIMAL(18,2)') ELSE 0 END),0),
               @TotalCreditos_Test = ISNULL(SUM(CASE WHEN T.c.value('@Tipo', 'CHAR(1)') = 'C' THEN T.c.value('@ValorCalculadoPartida', 'DECIMAL(18,2)') ELSE 0 END),0)
        FROM @PartidasXML.nodes('/Partidas/Partida') T(c);
    END;
    PRINT 'Partidas Geradas (Simulado):';
    SELECT T.c.value('@Tipo', 'CHAR(1)') AS Tipo, T.c.value('@Conta', 'VARCHAR(50)') AS Conta,
           T.c.value('@ValorCalculadoPartida', 'DECIMAL(18,2)') AS ValorPartida,
           T.c.value('Historico[1]', 'NVARCHAR(255)') AS Historico
    FROM @PartidasXML.nodes('/Partidas/Partida') T(c);

    IF @PartidasXML IS NULL BEGIN INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('PARTIDAS_DC', 'AVISO', 'Nenhuma partida D/C definida.'); END
    ELSE IF ROUND(@TotalDebitos_Test,2) <> ROUND(@TotalCreditos_Test,2) BEGIN
         INSERT INTO @ResultadoTeste (Fase, Status, Detalhes, PartidasGeradasXML) VALUES ('PARTIDAS_DC', 'ERRO_BALANCEAMENTO', CONCAT('Débitos: ', FORMAT(@TotalDebitos_Test, 'N', 'pt-BR'), ' <> Créditos: ', FORMAT(@TotalCreditos_Test, 'N', 'pt-BR')), @PartidasXML);
    END ELSE BEGIN
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes, PartidasGeradasXML) VALUES ('PARTIDAS_DC', 'OK', CONCAT('Débitos: ', FORMAT(@TotalDebitos_Test, 'N', 'pt-BR'), ', Créditos: ', FORMAT(@TotalCreditos_Test, 'N', 'pt-BR')), @PartidasXML);
    END
    SELECT Fase, Status, Detalhes, ValorCalculado, PartidasGeradasXML FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra');
END
GO

PRINT 'Criando/Alterando Stored Procedure sp_ExecutarValidacoesContabeis...';
GO
CREATE OR ALTER PROCEDURE dbo.sp_ExecutarValidacoesContabeis
    @P_ExecutionRunID UNIQUEIDENTIFIER,
    @P_NumeroLote INT,
    @P_PeriodoID INT,
    @P_EmpresaID VARCHAR(50),
    @P_Simulacao BIT = 0,
    @P_ParametrosGlobaisJSON NVARCHAR(MAX) = NULL -- Adicionado para consistência
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DataHoraAtual VARCHAR(23);
    DECLARE @GV_TaxaCambio DECIMAL(18,6), @GV_IndiceXPTO DECIMAL(18,6); -- Exemplo GVs

    IF ISJSON(@P_ParametrosGlobaisJSON) = 1
    BEGIN
        SELECT @GV_TaxaCambio = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.TaxaCambio'), @GV_IndiceXPTO = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.IndiceXPTO');
    END

    DECLARE @ValidacoesParaExecutar TABLE (
        ValidacaoID INT PRIMARY KEY, ValidacaoConceito VARCHAR(100), OrdemExecucao INT,
        DescricaoValidacao NVARCHAR(255), FormulaValidacaoSQL NVARCHAR(MAX),
        MensagemFalhaTemplate NVARCHAR(500), NivelSeveridade VARCHAR(20)
    );
    WITH ValidacoesPriorizadas AS (
        SELECT rv.ValidacaoID, rv.ValidacaoConceito, rv.OrdemExecucao, rv.DescricaoValidacao, rv.FormulaValidacaoSQL, rv.MensagemFalhaTemplate, rv.NivelSeveridade,
               ROW_NUMBER() OVER (PARTITION BY rv.ValidacaoConceito ORDER BY CASE WHEN rv.EmpresaEspecificaID = @P_EmpresaID THEN 0 ELSE 1 END ASC) as Prioridade
        FROM dbo.RegrasValidacao rv
        WHERE rv.Ativa = 1 AND (rv.EmpresaEspecificaID = @P_EmpresaID OR rv.EmpresaEspecificaID IS NULL)
    )
    INSERT INTO @ValidacoesParaExecutar SELECT ValidacaoID, ValidacaoConceito, OrdemExecucao, DescricaoValidacao, FormulaValidacaoSQL, MensagemFalhaTemplate, NivelSeveridade
    FROM ValidacoesPriorizadas WHERE Prioridade = 1;

    SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Iniciando Validações Pós-Execução (RunID: ', CAST(@P_ExecutionRunID AS VARCHAR(36)) ,'). Empresa: ', @P_EmpresaID, ', Período: ', @P_PeriodoID, ', Lote: ', @P_NumeroLote, IIF(@P_Simulacao=1, ' (SIMULAÇÃO)', ''));

    IF NOT EXISTS (SELECT 1 FROM @ValidacoesParaExecutar)
    BEGIN
        PRINT CONCAT(@DataHoraAtual, ' - INFO: Nenhuma regra de validação aplicável encontrada.');
        RETURN;
    END

    DECLARE @ValidacaoID_Current INT, @DescricaoValidacao_Current NVARCHAR(255), @FormulaValidacao_Current NVARCHAR(MAX),
            @MensagemFalha_Current NVARCHAR(500), @NivelSeveridade_Current VARCHAR(20);
    DECLARE @ResultadoValidacao_Count INT; DECLARE @StatusValidacaoAtual VARCHAR(20); DECLARE @DetalheResultadoParaLog NVARCHAR(MAX);

    DECLARE CursorValidacoes CURSOR LOCAL FAST_FORWARD FOR
        SELECT ValidacaoID, DescricaoValidacao, FormulaValidacaoSQL, MensagemFalhaTemplate, NivelSeveridade
        FROM @ValidacoesParaExecutar ORDER BY OrdemExecucao, ValidacaoID;
    OPEN CursorValidacoes;
    FETCH NEXT FROM CursorValidacoes INTO @ValidacaoID_Current, @DescricaoValidacao_Current, @FormulaValidacao_Current, @MensagemFalha_Current, @NivelSeveridade_Current;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121); SET @ResultadoValidacao_Count = 0;
        SET @DetalheResultadoParaLog = NULL; SET @StatusValidacaoAtual = 'OK';
        BEGIN TRY
            DECLARE @TempSQL_Validacao NVARCHAR(MAX) = N'SELECT @Cnt = COUNT(*) FROM (' + @FormulaValidacao_Current + N') AS SubQueryValidator;';
            EXEC sp_executesql @TempSQL_Validacao,
                               N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @P_NumeroLote_IN INT, @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @Cnt INT OUTPUT',
                               @P_PeriodoID_IN = @P_PeriodoID, @P_EmpresaID_IN = @P_EmpresaID, @P_NumeroLote_IN = @P_NumeroLote,
                               @GV_TaxaCambio_IN = @GV_TaxaCambio, @GV_IndiceXPTO_IN = @GV_IndiceXPTO,
                               @Cnt = @ResultadoValidacao_Count OUTPUT;
            IF @ResultadoValidacao_Count > 0
            BEGIN
                SET @StatusValidacaoAtual = IIF(@NivelSeveridade_Current = 'ERRO', 'FALHA_ERRO', 'FALHA_AVISO');
                SET @DetalheResultadoParaLog = REPLACE(@MensagemFalha_Current, '{ContagemFalhas}', CAST(@ResultadoValidacao_Count AS VARCHAR));
                PRINT CONCAT(@DataHoraAtual, ' - ', @StatusValidacaoAtual, ': Validação ID ', @ValidacaoID_Current, ' (', @DescricaoValidacao_Current, '). ', @DetalheResultadoParaLog);
            END ELSE BEGIN
                SET @DetalheResultadoParaLog = 'Validação passou com sucesso.';
                PRINT CONCAT(@DataHoraAtual, ' - OK: Validação ID ', @ValidacaoID_Current, ' (', @DescricaoValidacao_Current, ') executada com sucesso.');
            END
        END TRY
        BEGIN CATCH
            SET @StatusValidacaoAtual = 'ERRO_VALIDACAO_SQL'; SET @DetalheResultadoParaLog = CONCAT('Erro SQL Validação ID ', @ValidacaoID_Current, ': ', ERROR_MESSAGE());
            PRINT CONCAT(@DataHoraAtual, ' - ERRO: ', @DetalheResultadoParaLog);
        END CATCH
        INSERT INTO dbo.LogValidacoesExecutadas (ExecutionRunID, NumeroLote, ValidacaoID, PeriodoID, EmpresaID, StatusValidacao, ResultadoDetalhado, Simulacao)
        VALUES (@P_ExecutionRunID, @P_NumeroLote, @ValidacaoID_Current, @P_PeriodoID, @P_EmpresaID, @StatusValidacaoAtual, @DetalheResultadoParaLog, @P_Simulacao);
        FETCH NEXT FROM CursorValidacoes INTO @ValidacaoID_Current, @DescricaoValidacao_Current, @FormulaValidacao_Current, @MensagemFalha_Current, @NivelSeveridade_Current;
    END
    CLOSE CursorValidacoes; DEALLOCATE CursorValidacoes;
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Validações Pós-Execução concluídas (RunID: ', CAST(@P_ExecutionRunID AS VARCHAR(36)) ,').');
    SET NOCOUNT OFF;
END
GO

PRINT 'Script concluído.';
GO