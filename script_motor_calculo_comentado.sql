/*
====================================================================================================
SCRIPT SQL COMPILADO - SISTEMA DE CÁLCULO CONTÁBIL DINÂMICO (COM COMENTÁRIOS)
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

-- USE SEU_BANCO_DE_DADOS; -- <<<<<< ALTERE PARA O NOME DO SEU BANCO DE DADOS AQUI E DESCOMENTE
-- GO

PRINT 'Iniciando a criação/atualização dos objetos do banco de dados...';
GO

----------------------------------------------------------------------------------------------------
-- 1. TABELAS DE SUPORTE
-- Estas tabelas fornecem a estrutura básica para o plano de contas e para o registro
-- dos lançamentos contábeis gerados pelas regras.
----------------------------------------------------------------------------------------------------

-- Tabela PlanoContas (Exemplo)
PRINT 'Criando Tabela PlanoContas...';
IF OBJECT_ID('dbo.PlanoContas', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PlanoContas (
        PlanoContasUID INT IDENTITY(1,1) PRIMARY KEY, -- Identificador único do registo no plano de contas
        EmpresaID VARCHAR(50) NOT NULL,               -- Identificador da empresa à qual a conta pertence
        ContaID VARCHAR(50) NOT NULL,                 -- Código da conta contábil (ex: "1.01.01.001")
        DescricaoConta NVARCHAR(255) NOT NULL,        -- Descrição da conta contábil
        Natureza CHAR(1) NOT NULL CHECK (Natureza IN ('D', 'C')) -- Natureza da conta: 'D' para Devedora, 'C' para Credora
        CONSTRAINT UQ_PlanoContas_EmpresaConta UNIQUE (EmpresaID, ContaID) -- Garante que cada conta é única por empresa
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
        LancamentoID BIGINT IDENTITY(1,1) PRIMARY KEY, -- Identificador único do lançamento
        DataLancamento DATETIME NOT NULL,             -- Data em que o lançamento foi efetuado
        PeriodoID INT NOT NULL,                       -- Período contábil (ex: 202301 para Janeiro/2023)
        EmpresaID VARCHAR(50) NOT NULL,               -- Identificador da empresa
        RegraID INT NULL,                             -- ID da regra de cálculo que originou este lançamento (opcional)
        NumeroLote INT NULL,                          -- Número de lote para agrupar lançamentos de uma mesma execução da SP
        ContaContabil VARCHAR(50) NOT NULL,           -- Código da conta contábil afetada
        Historico NVARCHAR(500) NULL,                 -- Descrição/histórico do lançamento
        ValorDebito DECIMAL(18,2) NOT NULL DEFAULT 0, -- Valor do débito
        ValorCredito DECIMAL(18,2) NOT NULL DEFAULT 0,-- Valor do crédito
        CONSTRAINT CK_Lancamentos_DebitoCredito CHECK (ValorDebito >= 0 AND ValorCredito >= 0 AND (ValorDebito > 0 OR ValorCredito > 0) AND (ValorDebito = 0 OR ValorCredito = 0)) -- Garante que é ou débito ou crédito, mas não ambos, e que um deles é maior que zero.
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
-- Estas tabelas armazenam as definições das regras de cálculo e suas partidas.
-- O versionamento temporal permite auditar alterações nas regras ao longo do tempo.
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

-- Recriação da tabela RegrasCalculoContabil com versionamento
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
    RegraID INT IDENTITY(1,1) NOT NULL,             -- Identificador único da regra
    RegraConceito VARCHAR(100) NOT NULL,            -- Conceito funcional da regra (ex: 'CALC_JUROS_CONTRATO')
    DescricaoRegra NVARCHAR(255) NOT NULL,         -- Descrição textual da regra
    EmpresaEspecificaID VARCHAR(50) NULL,           -- Se NULL, é uma regra padrão. Se preenchido, é específica para a empresa.
    FormulaValorBase NVARCHAR(MAX) NOT NULL,        -- Fórmula SQL para calcular o valor principal da transação
    CondicaoExecucao NVARCHAR(MAX) NULL,            -- Condição SQL opcional para executar a regra
    OrdemExecucao INT NOT NULL DEFAULT 0,           -- Ordem de execução dos conceitos de regra
    Ativa BIT NOT NULL DEFAULT 1,                   -- Indica se a regra está ativa para execução
    StatusAprovacao VARCHAR(20) NOT NULL DEFAULT 'PENDENTE' CHECK (StatusAprovacao IN ('PENDENTE', 'APROVADA', 'REJEITADA', 'EM_REVISAO')), -- Status do workflow de aprovação
    AprovadoPor NVARCHAR(100) NULL,                 -- Usuário que aprovou a regra
    DataAprovacao DATETIME2 NULL,                   -- Data da aprovação
    SolicitadoPor NVARCHAR(100) NULL,               -- Usuário que solicitou/criou a regra
    DataSolicitacao DATETIME2 NULL DEFAULT GETDATE(),-- Data da solicitação/criação
    -- Colunas para versionamento temporal (System-Versioned Temporal Table)
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL, -- Início da validade da versão da linha
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,     -- Fim da validade da versão da linha
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),            -- Define o período de validade do sistema
    CONSTRAINT PK_RegrasCalculoContabil PRIMARY KEY (RegraID)      -- Chave primária
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.RegrasCalculoContabil_History)); -- Ativa o versionamento, especificando a tabela de histórico
PRINT 'Tabela RegrasCalculoContabil criada com versionamento temporal.';
GO
-- Índices para otimizar consultas e garantir unicidade
CREATE INDEX IX_RCC_ConceitoEmpresaAtiva ON dbo.RegrasCalculoContabil(RegraConceito, EmpresaEspecificaID, Ativa, StatusAprovacao);
CREATE UNIQUE INDEX UQ_RCC_ConceitoPadrao ON dbo.RegrasCalculoContabil(RegraConceito) WHERE EmpresaEspecificaID IS NULL; -- Garante um conceito padrão único
CREATE UNIQUE INDEX UQ_RCC_ConceitoEmpresa ON dbo.RegrasCalculoContabil(RegraConceito, EmpresaEspecificaID) WHERE EmpresaEspecificaID IS NOT NULL; -- Garante um conceito específico único por empresa
PRINT 'Índices para RegrasCalculoContabil criados.';
GO

PRINT 'Configurando Tabela RegrasCalculoPartidas com versionamento temporal...';
-- Recriação da tabela RegrasCalculoPartidas com versionamento
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
    PartidaID INT IDENTITY(1,1) NOT NULL,                   -- Identificador único da partida
    RegraID INT NOT NULL,                                   -- Chave estrangeira para RegrasCalculoContabil
    TipoPartida CHAR(1) NOT NULL CHECK (TipoPartida IN ('D', 'C')), -- 'D' para Débito, 'C' para Crédito
    ContaContabil VARCHAR(50) NOT NULL,                     -- Código da conta contábil a ser afetada
    PercentualSobreValorBase DECIMAL(18, 4) NOT NULL DEFAULT 100.00, -- Percentual do FormulaValorBase a ser aplicado
    HistoricoPadraoSugerido NVARCHAR(255) NULL,             -- Histórico específico para esta "perna" do lançamento
    -- Colunas para versionamento temporal
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
    CONSTRAINT PK_RegrasCalculoPartidas PRIMARY KEY (PartidaID), -- Chave primária
    CONSTRAINT FK_RCP_Regra FOREIGN KEY (RegraID) REFERENCES dbo.RegrasCalculoContabil(RegraID) ON DELETE CASCADE -- Garante integridade referencial e deleção em cascata
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
-- Estas tabelas são usadas para auditar a execução das regras e o workflow de aprovação.
----------------------------------------------------------------------------------------------------

PRINT 'Criando Tabela LogExecucaoRegras...';
IF OBJECT_ID('dbo.LogExecucaoRegras', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LogExecucaoRegras (
        LogID BIGINT IDENTITY(1,1) PRIMARY KEY,                 -- Identificador único do log
        ExecutionRunID UNIQUEIDENTIFIER NOT NULL,               -- ID único para toda uma execução da SP principal
        NumeroLote INT NULL,                                    -- Número do lote de lançamento contábil gerado
        DataProcessamento DATETIME2 NOT NULL DEFAULT GETDATE(), -- Data e hora do processamento da regra
        PeriodoID INT NOT NULL,                                 -- Período contábil processado
        EmpresaID VARCHAR(50) NOT NULL,                         -- Empresa processada
        RegraID INT NOT NULL,                                   -- ID da regra principal processada
        RegraConceito VARCHAR(100) NOT NULL,                    -- Conceito da regra processada
        RegraSysStartTime DATETIME2 NULL,                       -- Timestamp da versão da regra que foi executada (SysStartTime de RegrasCalculoContabil)
        DescricaoRegraProcessada NVARCHAR(255) NULL,           -- Descrição da regra no momento da execução
        CondicaoExecucaoDaRegra NVARCHAR(MAX) NULL,             -- A CondicaoExecucao que foi avaliada
        CondicaoSatisfeita BIT NULL,                            -- Resultado da avaliação da condição (1=Satisfeita, 0=Não)
        FormulaValorBaseDaRegra NVARCHAR(MAX) NULL,             -- A FormulaValorBase que foi usada
        ValorBaseCalculado DECIMAL(18,2) NULL,                  -- Valor base calculado pela fórmula
        TotalDebitosGerados DECIMAL(18,2) NULL,                 -- Soma dos débitos gerados pela regra
        TotalCreditosGerados DECIMAL(18,2) NULL,                -- Soma dos créditos gerados pela regra
        StatusExecucao VARCHAR(50) NOT NULL,                    -- Status final da execução da regra (ex: 'SUCESSO', 'FALHA_CONDICAO', 'ERRO_PARTIDAS_NAO_BATEM')
        MensagemDetalhada NVARCHAR(MAX) NULL,                   -- Mensagem de erro ou detalhes adicionais
        Simulacao BIT NOT NULL                                  -- 1 se foi uma simulação, 0 se foi execução real
    );
    CREATE INDEX IX_LogExecucaoRegras_RunID ON dbo.LogExecucaoRegras(ExecutionRunID);
    CREATE INDEX IX_LogExecucaoRegras_RegraPeriodoEmpresa ON dbo.LogExecucaoRegras(RegraID, PeriodoID, EmpresaID, DataProcessamento);
    CREATE INDEX IX_LogExecucaoRegras_StatusData ON dbo.LogExecucaoRegras(StatusExecucao, DataProcessamento);
    PRINT 'Tabela LogExecucaoRegras criada.';
END
ELSE
BEGIN
    -- Adiciona a coluna RegraSysStartTime se a tabela já existir e a coluna não
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
        LogAprovacaoID INT IDENTITY(1,1) PRIMARY KEY,           -- Identificador único do log de aprovação
        RegraID INT NOT NULL,                                   -- ID da regra que sofreu a ação
        RegraSysStartTime DATETIME2 NULL,                       -- Timestamp da versão da regra (se aplicável à ação)
        DataAcao DATETIME2 NOT NULL DEFAULT GETDATE(),          -- Data da ação de aprovação/rejeição
        UsuarioAcao NVARCHAR(100) NOT NULL,                     -- Usuário que realizou a ação
        StatusAnterior VARCHAR(20) NULL,                        -- Status de aprovação anterior da regra
        StatusNovo VARCHAR(20) NOT NULL,                        -- Novo status de aprovação da regra
        Comentarios NVARCHAR(MAX) NULL,                         -- Comentários sobre a ação
        CONSTRAINT FK_LogAprovacao_Regra FOREIGN KEY (RegraID) REFERENCES dbo.RegrasCalculoContabil(RegraID)
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
-- Estas tabelas definem regras de validação que podem ser executadas após o
-- processamento das regras de cálculo para verificar a integridade dos dados.
----------------------------------------------------------------------------------------------------

PRINT 'Criando Tabela RegrasValidacao...';
IF OBJECT_ID('dbo.RegrasValidacao', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RegrasValidacao (
        ValidacaoID INT IDENTITY(1,1) PRIMARY KEY,              -- Identificador único da regra de validação
        ValidacaoConceito VARCHAR(100) NOT NULL,                -- Conceito funcional da validação (ex: 'BALANCETE_CONFERE')
        DescricaoValidacao NVARCHAR(255) NOT NULL,             -- Descrição da regra de validação
        EmpresaEspecificaID VARCHAR(50) NULL,                   -- Se NULL, é padrão. Se preenchido, é específica para a empresa.
        FormulaValidacaoSQL NVARCHAR(MAX) NOT NULL,             -- SQL que retorna linhas SE A VALIDAÇÃO FALHAR
        MensagemFalhaTemplate NVARCHAR(500) NOT NULL,           -- Template da mensagem de falha (ex: 'Balancete não confere para período {PERIODO}')
        NivelSeveridade VARCHAR(20) NOT NULL DEFAULT 'AVISO' CHECK (NivelSeveridade IN ('AVISO', 'ERRO')), -- Nível de severidade da falha
        Ativa BIT NOT NULL DEFAULT 1,                           -- Indica se a regra de validação está ativa
        OrdemExecucao INT NOT NULL DEFAULT 0                    -- Ordem de execução das validações
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
        LogValidacaoID BIGINT IDENTITY(1,1) PRIMARY KEY,        -- Identificador único do log de validação
        ExecutionRunID UNIQUEIDENTIFIER NOT NULL,               -- ID da execução da SP principal que originou esta validação
        NumeroLote INT NULL,                                    -- Número do lote de lançamentos que está sendo validado
        ValidacaoID INT NOT NULL,                               -- ID da regra de validação executada
        DataValidacao DATETIME2 NOT NULL DEFAULT GETDATE(),     -- Data e hora da execução da validação
        PeriodoID INT NOT NULL,                                 -- Período contábil validado
        EmpresaID VARCHAR(50) NOT NULL,                         -- Empresa validada
        StatusValidacao VARCHAR(20) NOT NULL CHECK (StatusValidacao IN ('OK', 'FALHA_AVISO', 'FALHA_ERRO', 'ERRO_VALIDACAO_SQL')), -- Status da validação
        ResultadoDetalhado NVARCHAR(MAX) NULL,                  -- Detalhes do resultado (ex: JSON das inconsistências ou mensagem)
        Simulacao BIT NOT NULL,                                 -- 1 se foi uma simulação
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
    @P_ParametrosGlobaisJSON NVARCHAR(MAX) = NULL -- Parâmetro para Variáveis Globais (Item 7)
AS
BEGIN
    SET NOCOUNT ON; -- Evita mensagens "rows affected"
    SET XACT_ABORT ON; -- Garante que, se ocorrer um erro de execução, a transação seja revertida e a execução da SP interrompida (a menos que o erro seja capturado por TRY...CATCH que não o relance).

    -- Variáveis de controle e log
    DECLARE @LogMensagem NVARCHAR(MAX);
    DECLARE @DataHoraAtual VARCHAR(23);
    DECLARE @NumeroLoteAtual INT;
    DECLARE @ExecutionRunID UNIQUEIDENTIFIER = NEWID(); -- ID único para esta execução completa da SP

    -- Extração de Parâmetros Globais (Item 7)
    -- Estes são exemplos. Adicione/remova conforme necessário.
    -- As fórmulas nas regras devem ser escritas para usar estas variáveis (ex: @GV_TaxaCambio).
    DECLARE @GV_TaxaCambio DECIMAL(18,6), @GV_IndiceXPTO DECIMAL(18,6);
    IF ISJSON(@P_ParametrosGlobaisJSON) = 1
    BEGIN
        SELECT
            @GV_TaxaCambio = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.TaxaCambio'), -- Ex: '{"TaxaCambio": 5.25, "IndiceXPTO": 1.02}'
            @GV_IndiceXPTO = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.IndiceXPTO');
        -- É importante que as fórmulas que usam estas variáveis globais estejam preparadas para lidar com valores NULL,
        -- caso o JSON não contenha o parâmetro esperado ou o JSON seja inválido.
        -- Exemplo: ISNULL(@GV_TaxaCambio, 1.0) se uma taxa padrão for aplicável.
    END

    -- Geração do Número de Lote para agrupar os lançamentos contábeis
    IF @P_Simulacao = 0 -- Se não for simulação, bloqueia a tabela para obter o próximo lote com segurança
    BEGIN
        -- Em ambientes de alta concorrência, considere usar um objeto SEQUENCE para @NumeroLoteAtual
        -- para evitar contenção na tabela LancamentosContabeis.
        SELECT @NumeroLoteAtual = ISNULL(MAX(NumeroLote), 0) + 1 FROM dbo.LancamentosContabeis WITH (TABLOCKX, HOLDLOCK);
    END
    ELSE -- Para simulação, apenas lê o valor máximo
    BEGIN
        SELECT @NumeroLoteAtual = ISNULL(MAX(NumeroLote), 0) + 1 FROM dbo.LancamentosContabeis;
    END

    -- Tabela temporária para armazenar as regras principais que serão efetivamente processadas,
    -- após aplicar a lógica de sobrescrita (padrão vs. específica da empresa).
    DECLARE @RegrasCabecalhoParaExecucao TABLE (
        RegraID INT PRIMARY KEY,
        RegraConceito VARCHAR(100),
        OrdemExecucao INT,
        DescricaoRegra NVARCHAR(255),
        FormulaValorBase NVARCHAR(MAX),
        CondicaoExecucao NVARCHAR(MAX),
        RegraSysStartTime DATETIME2 -- Para logar a versão da regra (Item 3)
    );

    -- Seleção das regras a serem executadas, aplicando a lógica de prioridade:
    -- 1. Regra específica para a empresa (EmpresaEspecificaID = @P_EmpresaID)
    -- 2. Se não houver específica, usa a regra padrão (EmpresaEspecificaID IS NULL)
    -- Apenas regras Ativas e com StatusAprovacao = 'APROVADA' (Item 4) são consideradas.
    WITH RegrasPriorizadas AS (
        SELECT
            rc.RegraID, rc.RegraConceito, rc.OrdemExecucao, rc.DescricaoRegra,
            rc.FormulaValorBase, rc.CondicaoExecucao, rc.SysStartTime AS RegraSysStartTime,
            ROW_NUMBER() OVER (
                PARTITION BY rc.RegraConceito -- Para cada "tipo" de regra funcional
                ORDER BY CASE WHEN rc.EmpresaEspecificaID = @P_EmpresaID THEN 0 ELSE 1 END ASC -- Regra específica da empresa tem prioridade 0
            ) as Prioridade
        FROM dbo.RegrasCalculoContabil rc
        WHERE rc.Ativa = 1 AND rc.StatusAprovacao = 'APROVADA'
              AND (rc.EmpresaEspecificaID = @P_EmpresaID OR rc.EmpresaEspecificaID IS NULL)
    )
    INSERT INTO @RegrasCabecalhoParaExecucao
    SELECT RegraID, RegraConceito, OrdemExecucao, DescricaoRegra, FormulaValorBase, CondicaoExecucao, RegraSysStartTime
    FROM RegrasPriorizadas WHERE Prioridade = 1; -- Pega apenas a de maior prioridade para cada conceito

    SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Iniciando processamento (RunID: ', CAST(@ExecutionRunID AS VARCHAR(36)) ,'). Empresa: ', @P_EmpresaID, ', Período: ', @P_PeriodoID, ', Lote: ', @NumeroLoteAtual, IIF(@P_Simulacao=1, ' (SIMULAÇÃO)', ''));

    -- Se nenhuma regra for selecionada, loga e encerra.
    IF NOT EXISTS (SELECT 1 FROM @RegrasCabecalhoParaExecucao)
    BEGIN
        SET @LogMensagem = 'Nenhuma regra aplicável encontrada para os critérios fornecidos (ativa, aprovada, e correspondente à empresa/padrão).';
        PRINT CONCAT(@DataHoraAtual, ' - INFO: ', @LogMensagem);
        INSERT INTO dbo.LogExecucaoRegras (ExecutionRunID, NumeroLote, PeriodoID, EmpresaID, RegraID, RegraConceito, DescricaoRegraProcessada, StatusExecucao, MensagemDetalhada, Simulacao)
        VALUES (@ExecutionRunID, @NumeroLoteAtual, @P_PeriodoID, @P_EmpresaID, 0, 'N/A_SETUP', NULL, 'INFO_SEM_REGRAS', @LogMensagem, @P_Simulacao);
        RETURN;
    END

    -- Variáveis para o loop de processamento das regras
    DECLARE @RegraID_Current INT, @RegraConceito_Current VARCHAR(100), @DescricaoRegra_Current NVARCHAR(255),
            @FormulaValorBase_Current NVARCHAR(MAX), @CondicaoExecucao_Current_Text NVARCHAR(MAX),
            @RegraSysStartTime_Current DATETIME2;
    -- Variáveis para o loop de processamento das partidas D/C
    DECLARE @Partida_TipoPartida CHAR(1), @Partida_ContaContabil VARCHAR(50),
            @Partida_Percentual DECIMAL(18,4), @Partida_HistoricoSugerido NVARCHAR(255);
    -- Variáveis para execução de SQL dinâmico e resultados
    DECLARE @SQL_Dynamic NVARCHAR(MAX), @Parametros_Definition NVARCHAR(MAX),
            @CondicaoSatisfeita_Result BIT, @ValorBaseCalculado_Result DECIMAL(18,2), @ValorPartidaCalculado DECIMAL(18,2);
    -- Variáveis para totalizar débitos e créditos por regra
    DECLARE @TotalDebitosLote_Regra DECIMAL(18,2), @TotalCreditosLote_Regra DECIMAL(18,2);
    DECLARE @StatusExecucaoAtual VARCHAR(50); -- Status para o log

    -- Cursor para iterar sobre as regras principais selecionadas
    DECLARE CursorRegrasCabecalho CURSOR LOCAL FAST_FORWARD FOR -- Otimizações de cursor
        SELECT RegraID, RegraConceito, DescricaoRegra, FormulaValorBase, CondicaoExecucao, RegraSysStartTime
        FROM @RegrasCabecalhoParaExecucao ORDER BY OrdemExecucao, RegraID; -- Processa na ordem definida

    OPEN CursorRegrasCabecalho;
    FETCH NEXT FROM CursorRegrasCabecalho INTO @RegraID_Current, @RegraConceito_Current, @DescricaoRegra_Current, @FormulaValorBase_Current, @CondicaoExecucao_Current_Text, @RegraSysStartTime_Current;

    WHILE @@FETCH_STATUS = 0 -- Loop principal para cada regra
    BEGIN
        -- Reinicializa variáveis para cada regra
        SET @ValorBaseCalculado_Result = NULL; SET @CondicaoSatisfeita_Result = 1; -- Condição é satisfeita por padrão se não houver texto
        SET @TotalDebitosLote_Regra = 0; SET @TotalCreditosLote_Regra = 0;
        SET @StatusExecucaoAtual = NULL; SET @LogMensagem = NULL;
        SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);

        -- Inicia uma transação para cada regra principal. Se algo falhar, apenas esta regra é revertida.
        IF @P_Simulacao = 0 BEGIN TRANSACTION RegraExecucao;

        BEGIN TRY
            -- Etapa 1: Avaliar a Condição de Execução da Regra Principal
            IF @CondicaoExecucao_Current_Text IS NOT NULL AND LTRIM(RTRIM(@CondicaoExecucao_Current_Text)) <> ''
            BEGIN
                BEGIN TRY
                    SET @SQL_Dynamic = N'SELECT @CondResult_OUT = CASE WHEN (' + @CondicaoExecucao_Current_Text + N') THEN 1 ELSE 0 END;';
                    -- Inclui os parâmetros globais na definição para sp_executesql
                    SET @Parametros_Definition = N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @CondResult_OUT BIT OUTPUT';
                    EXEC sp_executesql @SQL_Dynamic, @Parametros_Definition,
                                       @P_PeriodoID_IN = @P_PeriodoID, @P_EmpresaID_IN = @P_EmpresaID,
                                       @GV_TaxaCambio_IN = @GV_TaxaCambio, @GV_IndiceXPTO_IN = @GV_IndiceXPTO, -- Passa os GVs
                                       @CondResult_OUT = @CondicaoSatisfeita_Result OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @StatusExecucaoAtual = 'ERRO_CONDICAO_SQL'; SET @LogMensagem = CONCAT('Falha ao avaliar CondicaoExecucao SQL: ', @CondicaoExecucao_Current_Text, '. Erro: ', ERROR_MESSAGE()); THROW; -- Pula para o CATCH principal da regra
                END CATCH
            END

            IF @CondicaoSatisfeita_Result = 0
            BEGIN
                SET @StatusExecucaoAtual = 'FALHA_CONDICAO'; SET @LogMensagem = CONCAT('Condição (', LEFT(ISNULL(@CondicaoExecucao_Current_Text,'N/A'),100), '...) não satisfeita.');
                PRINT CONCAT(@DataHoraAtual, ' - INFO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                THROW; -- Pula para o CATCH principal para logar e continuar para a próxima regra
            END

            -- Etapa 2: Calcular o Valor Base da Regra Principal
            BEGIN TRY
                SET @SQL_Dynamic = N'SELECT @ValorBase_OUT = ISNULL((' + @FormulaValorBase_Current + N'), 0);'; -- ISNULL para evitar erro se a fórmula retornar NULL
                SET @Parametros_Definition = N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @ValorBase_OUT DECIMAL(18,2) OUTPUT';
                EXEC sp_executesql @SQL_Dynamic, @Parametros_Definition,
                                   @P_PeriodoID_IN = @P_PeriodoID, @P_EmpresaID_IN = @P_EmpresaID,
                                   @GV_TaxaCambio_IN = @GV_TaxaCambio, @GV_IndiceXPTO_IN = @GV_IndiceXPTO, -- Passa os GVs
                                   @ValorBase_OUT = @ValorBaseCalculado_Result OUTPUT;
            END TRY
            BEGIN CATCH
                SET @StatusExecucaoAtual = 'ERRO_FORMULA_BASE_SQL'; SET @LogMensagem = CONCAT('Falha ao avaliar FormulaValorBase SQL: ', @FormulaValorBase_Current, '. Erro: ', ERROR_MESSAGE()); THROW;
            END CATCH

            IF @ValorBaseCalculado_Result = 0 -- Se o valor base for zero, a regra pode não precisar gerar lançamentos.
            BEGIN
                SET @StatusExecucaoAtual = 'INFO_VALOR_BASE_ZERO'; SET @LogMensagem = 'Valor Base calculado é ZERO. Nenhuma partida gerada.';
                PRINT CONCAT(@DataHoraAtual, ' - INFO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                THROW; -- Pula para o CATCH principal para logar
            END

            -- Etapa 3: Processar Partidas (Débitos e Créditos) associadas à Regra Principal
            DECLARE @PartidasDefinidas BIT = 0;
            DECLARE CursorPartidas CURSOR LOCAL FAST_FORWARD FOR
                SELECT TipoPartida, ContaContabil, PercentualSobreValorBase, HistoricoPadraoSugerido
                FROM dbo.RegrasCalculoPartidas WHERE RegraID = @RegraID_Current; -- Busca as partidas da versão atual
            OPEN CursorPartidas;
            FETCH NEXT FROM CursorPartidas INTO @Partida_TipoPartida, @Partida_ContaContabil, @Partida_Percentual, @Partida_HistoricoSugerido;

            IF @@FETCH_STATUS = 0 SET @PartidasDefinidas = 1; -- Marca se encontrou pelo menos uma partida

            WHILE @@FETCH_STATUS = 0 -- Loop para cada partida D/C
            BEGIN
                SET @ValorPartidaCalculado = ROUND(@ValorBaseCalculado_Result * (@Partida_Percentual / 100.00), 2); -- Calcula o valor da partida
                DECLARE @HistoricoFinalPartida NVARCHAR(500) = ISNULL(@Partida_HistoricoSugerido, @DescricaoRegra_Current); -- Define o histórico
                
                -- Valida se a conta contábil da partida existe no plano de contas da empresa
                IF NOT EXISTS (SELECT 1 FROM dbo.PlanoContas pc WHERE pc.ContaID = @Partida_ContaContabil AND pc.EmpresaID = @P_EmpresaID)
                BEGIN
                    SET @StatusExecucaoAtual = 'ERRO_CONTA_INVALIDA'; SET @LogMensagem = CONCAT('Conta Contábil ', @Partida_ContaContabil, ' da partida não encontrada no Plano de Contas para Empresa ', @P_EmpresaID, '.'); THROW;
                END

                PRINT CONCAT(@DataHoraAtual, '   - Partida Regra ID ', @RegraID_Current,': ', @Partida_TipoPartida, ', Cta: ', @Partida_ContaContabil, ', Valor: ', FORMAT(@ValorPartidaCalculado, 'N', 'pt-BR'));

                IF @P_Simulacao = 0 -- Só insere se não for simulação
                BEGIN
                    INSERT INTO dbo.LancamentosContabeis (DataLancamento, PeriodoID, EmpresaID, RegraID, NumeroLote, ContaContabil, Historico, ValorDebito, ValorCredito)
                    VALUES (GETDATE(), @P_PeriodoID, @P_EmpresaID, @RegraID_Current, @NumeroLoteAtual, @Partida_ContaContabil, @HistoricoFinalPartida,
                            IIF(@Partida_TipoPartida = 'D', @ValorPartidaCalculado, 0), -- Se Débito, preenche ValorDebito
                            IIF(@Partida_TipoPartida = 'C', @ValorPartidaCalculado, 0)); -- Se Crédito, preenche ValorCredito
                END
                -- Acumula totais para validação de partidas dobradas
                IF @Partida_TipoPartida = 'D' SET @TotalDebitosLote_Regra = @TotalDebitosLote_Regra + @ValorPartidaCalculado;
                IF @Partida_TipoPartida = 'C' SET @TotalCreditosLote_Regra = @TotalCreditosLote_Regra + @ValorPartidaCalculado;
                FETCH NEXT FROM CursorPartidas INTO @Partida_TipoPartida, @Partida_ContaContabil, @Partida_Percentual, @Partida_HistoricoSugerido;
            END
            CLOSE CursorPartidas; DEALLOCATE CursorPartidas;

            IF @PartidasDefinidas = 0 -- Se a regra não tem nenhuma partida D/C definida
            BEGIN
                SET @StatusExecucaoAtual = 'FALHA_SEM_PARTIDAS'; SET @LogMensagem = 'Nenhuma partida (D/C) definida para a regra.';
                PRINT CONCAT(@DataHoraAtual, ' - AVISO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
                IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao;
                THROW; -- Pula para o CATCH para logar
            END

            -- Etapa 4: Validar Partidas Dobradas para a regra atual (após arredondamentos)
            IF ROUND(@TotalDebitosLote_Regra,2) <> ROUND(@TotalCreditosLote_Regra,2)
            BEGIN
                SET @StatusExecucaoAtual = 'ERRO_PARTIDAS_NAO_BATEM'; SET @LogMensagem = CONCAT('Desbalanceamento D/C. Débitos: ', FORMAT(@TotalDebitosLote_Regra, 'N', 'pt-BR'), ' <> Créditos: ', FORMAT(@TotalCreditosLote_Regra, 'N', 'pt-BR'));
                THROW; -- Força o CATCH para rollback da transação desta regra
            END

            -- Se tudo correu bem para esta regra
            SET @StatusExecucaoAtual = 'SUCESSO';
            SET @LogMensagem = CONCAT('Regra processada. Débitos: ', FORMAT(@TotalDebitosLote_Regra, 'N', 'pt-BR'), ', Créditos: ', FORMAT(@TotalCreditosLote_Regra, 'N', 'pt-BR'));
            PRINT CONCAT(@DataHoraAtual, ' - SUCESSO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, ') ', @LogMensagem);
            IF @P_Simulacao = 0 COMMIT TRANSACTION RegraExecucao; -- Commita a transação da regra

        END TRY
        BEGIN CATCH -- Bloco CATCH para a regra individual
            IF @@TRANCOUNT > 0 AND @P_Simulacao = 0 ROLLBACK TRANSACTION RegraExecucao; -- Garante rollback da transação da regra em caso de erro
            SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
            IF @StatusExecucaoAtual IS NULL SET @StatusExecucaoAtual = 'ERRO_GERAL_PROCESSAMENTO'; -- Status genérico se não foi definido antes
            IF @LogMensagem IS NULL SET @LogMensagem = ERROR_MESSAGE(); ELSE SET @LogMensagem = CONCAT(@LogMensagem, ' | Erro SQL: ', ERROR_MESSAGE(), ' Linha: ', ERROR_LINE());

            PRINT CONCAT(@DataHoraAtual, ' - ERRO CRÍTICO: Regra ID ', @RegraID_Current, ' (', @DescricaoRegra_Current, '). Status: ',@StatusExecucaoAtual, '. Mensagem: ', @LogMensagem);
            -- Limpeza de cursores internos se abertos e erro ocorreu antes do fechamento normal
            IF CURSOR_STATUS('local', 'CursorPartidas') >= 0 CLOSE CursorPartidas;
            IF CURSOR_STATUS('local', 'CursorPartidas') >= -1 DEALLOCATE CursorPartidas;
            -- O erro é capturado, logado, e o loop principal continua para a próxima regra.
            -- Se desejar parar toda a SP em caso de erro em uma regra, adicione THROW; aqui.
        END CATCH

        -- Registrar o resultado final da tentativa de processamento da regra no Log
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
    END -- Fim do loop principal de regras
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
    @P_ParametrosGlobaisJSON NVARCHAR(MAX) = NULL, -- Parâmetros globais para o teste (Item 7)
    @P_ValoresMockJSON NVARCHAR(MAX) = NULL -- JSON com valores mock (Item 2 - implementação de mock é complexa)
AS
BEGIN
    SET NOCOUNT ON;
    -- Tabela temporária para armazenar os resultados do teste em fases
    DECLARE @ResultadoTeste TABLE (
        Fase VARCHAR(100),
        Status VARCHAR(20),
        Detalhes NVARCHAR(MAX),
        ValorCalculado DECIMAL(18,2) NULL,
        PartidasGeradasXML XML NULL -- Para armazenar as partidas como XML para fácil visualização
    );

    -- Variáveis para armazenar a definição da regra
    DECLARE @RegraConceito_Test VARCHAR(100), @DescricaoRegra_Test NVARCHAR(255),
            @FormulaValorBase_Test NVARCHAR(MAX), @CondicaoExecucao_Test NVARCHAR(MAX);

    -- Extração de Parâmetros Globais para o teste
    DECLARE @GV_TaxaCambio DECIMAL(18,6), @GV_IndiceXPTO DECIMAL(18,6);
    IF ISJSON(@P_ParametrosGlobaisJSON) = 1
    BEGIN
        SELECT @GV_TaxaCambio = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.TaxaCambio'),
               @GV_IndiceXPTO = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.IndiceXPTO');
    END

    -- 1. Recuperar a definição da regra (versão atual, ativa e aprovada)
    SELECT TOP 1
           @RegraConceito_Test = rc.RegraConceito, @DescricaoRegra_Test = rc.DescricaoRegra,
           @FormulaValorBase_Test = rc.FormulaValorBase, @CondicaoExecucao_Test = rc.CondicaoExecucao
    FROM dbo.RegrasCalculoContabil rc
    WHERE rc.RegraID = @P_RegraID_ParaTeste AND rc.Ativa = 1 AND rc.StatusAprovacao = 'APROVADA';

    IF @FormulaValorBase_Test IS NULL -- Se a regra não for encontrada ou não atender aos critérios
    BEGIN
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('SETUP_REGRA', 'ERRO', CONCAT('RegraID ', @P_RegraID_ParaTeste, ' não encontrada, inativa ou não aprovada.'));
        SELECT Fase, Status, Detalhes FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra'); -- Retorna o erro como JSON
        RETURN;
    END

    PRINT '--- TESTE DE REGRA ID: ' + CAST(@P_RegraID_ParaTeste AS VARCHAR) + ' ---';
    PRINT 'Descrição: ' + @DescricaoRegra_Test;

    -- 2. Avaliar Condição de Execução
    DECLARE @CondicaoSatisfeita_Test BIT = 1; -- Assume satisfeita se não houver condição
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
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('CONDICAO_EXECUCAO', 'N/A', 'Sem condição definida.');
        PRINT 'Condição: N/A';
    END

    IF @CondicaoSatisfeita_Test = 0 -- Se a condição não for satisfeita, o teste para aqui para esta fase.
    BEGIN
        SELECT Fase, Status, Detalhes FROM @ResultadoTeste FOR JSON PATH, ROOT('ResultadoTesteRegra'); RETURN;
    END

    -- 3. Calcular Valor Base
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

    -- 4. Gerar Partidas D/C (simulado) e verificar balanceamento
    DECLARE @TotalDebitos_Test DECIMAL(18,2) = 0, @TotalCreditos_Test DECIMAL(18,2) = 0;
    DECLARE @PartidasXML XML; -- Armazena as partidas como XML para fácil visualização no resultado

    -- Constrói um XML com as partidas que seriam geradas
    SELECT @PartidasXML = (
        SELECT
            rp.TipoPartida AS "@Tipo",
            rp.ContaContabil AS "@Conta",
            rp.PercentualSobreValorBase AS "@Percentual",
            ROUND(@ValorBaseCalculado_Test * (rp.PercentualSobreValorBase / 100.00), 2) AS "@ValorCalculadoPartida",
            ISNULL(rp.HistoricoPadraoSugerido, @DescricaoRegra_Test) AS "Historico"
        FROM dbo.RegrasCalculoPartidas rp
        WHERE rp.RegraID = @P_RegraID_ParaTeste -- Considera apenas a versão atual das partidas
        FOR XML PATH('Partida'), ROOT('Partidas')
    );

    -- Calcula os totais de débito e crédito a partir do XML gerado
    IF @PartidasXML IS NOT NULL
    BEGIN
        SELECT
            @TotalDebitos_Test = ISNULL(SUM(CASE WHEN T.c.value('@Tipo', 'CHAR(1)') = 'D' THEN T.c.value('@ValorCalculadoPartida', 'DECIMAL(18,2)') ELSE 0 END),0),
            @TotalCreditos_Test = ISNULL(SUM(CASE WHEN T.c.value('@Tipo', 'CHAR(1)') = 'C' THEN T.c.value('@ValorCalculadoPartida', 'DECIMAL(18,2)') ELSE 0 END),0)
        FROM @PartidasXML.nodes('/Partidas/Partida') T(c); -- Extrai dados do XML
    END;

    PRINT 'Partidas Geradas (Simulado):';
    -- Imprime as partidas para visualização no painel de mensagens do SSMS
    SELECT
        T.c.value('@Tipo', 'CHAR(1)') AS Tipo,
        T.c.value('@Conta', 'VARCHAR(50)') AS Conta,
        T.c.value('@ValorCalculadoPartida', 'DECIMAL(18,2)') AS ValorPartida,
        T.c.value('Historico[1]', 'NVARCHAR(255)') AS Historico
    FROM @PartidasXML.nodes('/Partidas/Partida') T(c);

    -- Insere o resultado da fase de partidas na tabela de resultados do teste
    IF @PartidasXML IS NULL
    BEGIN
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes) VALUES ('PARTIDAS_DC', 'AVISO', 'Nenhuma partida D/C definida para a regra.');
    END
    ELSE IF ROUND(@TotalDebitos_Test,2) <> ROUND(@TotalCreditos_Test,2) -- Verifica se débitos e créditos batem
    BEGIN
         INSERT INTO @ResultadoTeste (Fase, Status, Detalhes, PartidasGeradasXML) VALUES ('PARTIDAS_DC', 'ERRO_BALANCEAMENTO', CONCAT('Débitos: ', FORMAT(@TotalDebitos_Test, 'N', 'pt-BR'), ' <> Créditos: ', FORMAT(@TotalCreditos_Test, 'N', 'pt-BR')), @PartidasXML);
    END
    ELSE
    BEGIN
        INSERT INTO @ResultadoTeste (Fase, Status, Detalhes, PartidasGeradasXML) VALUES ('PARTIDAS_DC', 'OK', CONCAT('Débitos: ', FORMAT(@TotalDebitos_Test, 'N', 'pt-BR'), ', Créditos: ', FORMAT(@TotalCreditos_Test, 'N', 'pt-BR')), @PartidasXML);
    END

    -- Retornar todos os resultados do teste como um único JSON
    SELECT Fase, Status, Detalhes, ValorCalculado, PartidasGeradasXML
    FROM @ResultadoTeste
    FOR JSON PATH, ROOT('ResultadoTesteRegra'); -- Formata a saída como JSON
END
GO

PRINT 'Criando/Alterando Stored Procedure sp_ExecutarValidacoesContabeis...';
GO
CREATE OR ALTER PROCEDURE dbo.sp_ExecutarValidacoesContabeis
    @P_ExecutionRunID UNIQUEIDENTIFIER, -- ID da execução das regras de cálculo que está sendo validada
    @P_NumeroLote INT,                   -- Número do lote de lançamentos gerado
    @P_PeriodoID INT,
    @P_EmpresaID VARCHAR(50),
    @P_Simulacao BIT = 0,
    @P_ParametrosGlobaisJSON NVARCHAR(MAX) = NULL -- Parâmetros globais (Item 7)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DataHoraAtual VARCHAR(23);

    -- Extração de Parâmetros Globais (similar à SP principal)
    DECLARE @GV_TaxaCambio DECIMAL(18,6), @GV_IndiceXPTO DECIMAL(18,6);
    IF ISJSON(@P_ParametrosGlobaisJSON) = 1
    BEGIN
        SELECT @GV_TaxaCambio = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.TaxaCambio'),
               @GV_IndiceXPTO = JSON_VALUE(@P_ParametrosGlobaisJSON, '$.IndiceXPTO');
    END

    -- Tabela temporária para as regras de validação selecionadas
    DECLARE @ValidacoesParaExecutar TABLE (
        ValidacaoID INT PRIMARY KEY, ValidacaoConceito VARCHAR(100), OrdemExecucao INT,
        DescricaoValidacao NVARCHAR(255), FormulaValidacaoSQL NVARCHAR(MAX),
        MensagemFalhaTemplate NVARCHAR(500), NivelSeveridade VARCHAR(20)
    );

    -- Seleciona as regras de validação (com lógica de prioridade empresa vs. padrão)
    WITH ValidacoesPriorizadas AS (
        SELECT rv.ValidacaoID, rv.ValidacaoConceito, rv.OrdemExecucao, rv.DescricaoValidacao,
               rv.FormulaValidacaoSQL, rv.MensagemFalhaTemplate, rv.NivelSeveridade,
               ROW_NUMBER() OVER (PARTITION BY rv.ValidacaoConceito ORDER BY CASE WHEN rv.EmpresaEspecificaID = @P_EmpresaID THEN 0 ELSE 1 END ASC) as Prioridade
        FROM dbo.RegrasValidacao rv
        WHERE rv.Ativa = 1 AND (rv.EmpresaEspecificaID = @P_EmpresaID OR rv.EmpresaEspecificaID IS NULL)
    )
    INSERT INTO @ValidacoesParaExecutar
    SELECT ValidacaoID, ValidacaoConceito, OrdemExecucao, DescricaoValidacao, FormulaValidacaoSQL, MensagemFalhaTemplate, NivelSeveridade
    FROM ValidacoesPriorizadas WHERE Prioridade = 1;

    SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121);
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Iniciando Validações Pós-Execução (RunID Cálculos: ', CAST(@P_ExecutionRunID AS VARCHAR(36)) ,'). Empresa: ', @P_EmpresaID, ', Período: ', @P_PeriodoID, ', Lote Cálculos: ', @P_NumeroLote, IIF(@P_Simulacao=1, ' (SIMULAÇÃO VALIDAÇÃO)', ''));

    IF NOT EXISTS (SELECT 1 FROM @ValidacoesParaExecutar)
    BEGIN
        PRINT CONCAT(@DataHoraAtual, ' - INFO: Nenhuma regra de validação aplicável encontrada.');
        RETURN;
    END

    -- Variáveis para o loop de validações
    DECLARE @ValidacaoID_Current INT, @DescricaoValidacao_Current NVARCHAR(255), @FormulaValidacao_Current NVARCHAR(MAX),
            @MensagemFalha_Current NVARCHAR(500), @NivelSeveridade_Current VARCHAR(20);
    DECLARE @ResultadoValidacao_Count INT; -- Usado para contar as falhas retornadas pela FormulaValidacaoSQL
    DECLARE @StatusValidacaoAtual VARCHAR(20); DECLARE @DetalheResultadoParaLog NVARCHAR(MAX);

    DECLARE CursorValidacoes CURSOR LOCAL FAST_FORWARD FOR
        SELECT ValidacaoID, DescricaoValidacao, FormulaValidacaoSQL, MensagemFalhaTemplate, NivelSeveridade
        FROM @ValidacoesParaExecutar ORDER BY OrdemExecucao, ValidacaoID;
    OPEN CursorValidacoes;
    FETCH NEXT FROM CursorValidacoes INTO @ValidacaoID_Current, @DescricaoValidacao_Current, @FormulaValidacao_Current, @MensagemFalha_Current, @NivelSeveridade_Current;

    WHILE @@FETCH_STATUS = 0 -- Loop para cada regra de validação
    BEGIN
        SET @DataHoraAtual = CONVERT(VARCHAR, SYSDATETIME(), 121); SET @ResultadoValidacao_Count = 0;
        SET @DetalheResultadoParaLog = NULL; SET @StatusValidacaoAtual = 'OK'; -- Padrão é OK
        BEGIN TRY
            -- A FormulaValidacaoSQL deve retornar linhas se a validação FALHAR.
            -- Contamos quantas linhas são retornadas.
            DECLARE @TempSQL_Validacao NVARCHAR(MAX) = N'SELECT @Cnt = COUNT(*) FROM (' + @FormulaValidacao_Current + N') AS SubQueryValidator;';
            EXEC sp_executesql @TempSQL_Validacao,
                               N'@P_PeriodoID_IN INT, @P_EmpresaID_IN VARCHAR(50), @P_NumeroLote_IN INT, @GV_TaxaCambio_IN DECIMAL(18,6), @GV_IndiceXPTO_IN DECIMAL(18,6), @Cnt INT OUTPUT',
                               @P_PeriodoID_IN = @P_PeriodoID, @P_EmpresaID_IN = @P_EmpresaID, @P_NumeroLote_IN = @P_NumeroLote,
                               @GV_TaxaCambio_IN = @GV_TaxaCambio, @GV_IndiceXPTO_IN = @GV_IndiceXPTO, -- Passa GVs
                               @Cnt = @ResultadoValidacao_Count OUTPUT;

            IF @ResultadoValidacao_Count > 0 -- Se retornou linhas, a validação falhou
            BEGIN
                SET @StatusValidacaoAtual = IIF(@NivelSeveridade_Current = 'ERRO', 'FALHA_ERRO', 'FALHA_AVISO');
                -- Formata a mensagem de falha usando o template e a contagem de falhas
                SET @DetalheResultadoParaLog = REPLACE(@MensagemFalha_Current, '{ContagemFalhas}', CAST(@ResultadoValidacao_Count AS VARCHAR));
                PRINT CONCAT(@DataHoraAtual, ' - ', @StatusValidacaoAtual, ': Validação ID ', @ValidacaoID_Current, ' (', @DescricaoValidacao_Current, '). ', @DetalheResultadoParaLog);
            END ELSE BEGIN -- Nenhuma linha retornada, validação OK
                SET @DetalheResultadoParaLog = 'Validação passou com sucesso.';
                PRINT CONCAT(@DataHoraAtual, ' - OK: Validação ID ', @ValidacaoID_Current, ' (', @DescricaoValidacao_Current, ') executada com sucesso.');
            END
        END TRY
        BEGIN CATCH -- Erro na execução da SQL da validação em si
            SET @StatusValidacaoAtual = 'ERRO_VALIDACAO_SQL'; SET @DetalheResultadoParaLog = CONCAT('Erro SQL ao executar Validação ID ', @ValidacaoID_Current, ': ', ERROR_MESSAGE());
            PRINT CONCAT(@DataHoraAtual, ' - ERRO: ', @DetalheResultadoParaLog);
        END CATCH

        -- Loga o resultado da validação
        INSERT INTO dbo.LogValidacoesExecutadas (ExecutionRunID, NumeroLote, ValidacaoID, PeriodoID, EmpresaID, StatusValidacao, ResultadoDetalhado, Simulacao)
        VALUES (@P_ExecutionRunID, @P_NumeroLote, @ValidacaoID_Current, @P_PeriodoID, @P_EmpresaID, @StatusValidacaoAtual, @DetalheResultadoParaLog, @P_Simulacao);

        FETCH NEXT FROM CursorValidacoes INTO @ValidacaoID_Current, @DescricaoValidacao_Current, @FormulaValidacao_Current, @MensagemFalha_Current, @NivelSeveridade_Current;
    END
    CLOSE CursorValidacoes; DEALLOCATE CursorValidacoes;
    PRINT CONCAT(@DataHoraAtual, ' - INFO: Validações Pós-Execução concluídas (RunID Cálculos: ', CAST(@P_ExecutionRunID AS VARCHAR(36)) ,').');
    SET NOCOUNT OFF;
END
GO

PRINT 'Script concluído.';
GO

