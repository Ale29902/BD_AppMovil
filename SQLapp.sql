CREATE DATABASE APP_PROYECTOM
GO
USE APP_PROYECTOM
GO

-- Configuración de la base de datos
ALTER AUTHORIZATION ON DATABASE::APP_PROYECTOM TO sa
SET DATEFORMAT DMY
SET LANGUAGE SPANISH
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Tabla de Usuarios
CREATE TABLE USUARIO (
    ID_USUARIO BIGINT IDENTITY(1,1) NOT NULL,
    NOMBRE NVARCHAR(50) NOT NULL,
    APELLIDO1 NVARCHAR(50) NOT NULL,
    APELLIDO2 NVARCHAR(50) NOT NULL,
    CORREO_ELECTRONICO NVARCHAR(50) NOT NULL UNIQUE,
    USUARIO NVARCHAR(50) NOT NULL UNIQUE,
    PASSWORD NVARCHAR(MAX) NOT NULL, 
    FECHA_NACIMIENTO SMALLDATETIME NULL,
    TIPO NVARCHAR(35) NOT NULL CHECK (TIPO IN ('Paciente', 'Encargado')),
    UBICACION NVARCHAR(MAX) NULL,
    IMAGEN VARBINARY(MAX) NULL,
    USUARIO_PACIENTE NVARCHAR(50) NULL UNIQUE,
    CONSTRAINT PK_USUARIO PRIMARY KEY CLUSTERED (ID_USUARIO ASC)
) ON [PRIMARY];
GO

CREATE TABLE DISPOSITIVOS(
ID_DISPOSITIVO BIGINT IDENTITY(1,1) NOT NULL,
DIRECCION_IP VARCHAR(45) NOT NULL,
NOMBRE_DISPOSITIVO NVARCHAR (45),
ID_USUARIO BIGINT NOT NULL,
ULTIMA_VEZ smalldatetime not null,
ACTIVO BIT DEFAULT 1
CONSTRAINT FK_USUARIO_DISPOSITIVO FOREIGN KEY (ID_USUARIO) REFERENCES USUARIO(ID_USUARIO),
CONSTRAINT PK_DISPOSITIVO PRIMARY KEY CLUSTERED (ID_DISPOSITIVO ASC) ) ON [PRIMARY];
GO

CREATE TRIGGER TRG_LimitarDispositivos
ON DISPOSITIVOS
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Verificar si el usuario tiene más de 3 dispositivos registrados
    IF EXISTS (
        SELECT 1 
        FROM DISPOSITIVOS d
        JOIN inserted i ON d.ID_USUARIO = i.ID_USUARIO
        WHERE d.ACTIVO = 1
        GROUP BY d.ID_USUARIO
        HAVING COUNT(d.ID_DISPOSITIVO) > 3
    )
    BEGIN
        RAISERROR('No puedes iniciar sesión en más de 3 dispositivos.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END;
GO




CREATE TABLE SOLICITUD_cuidador (
    ID_SOLICITUD BIGINT IDENTITY(1,1) NOT NULL,
    ID_USUARIO_SOLICITANTE BIGINT NOT NULL, 
    ID_USUARIO_DESTINATARIO BIGINT NOT NULL, 
    ESTADO NVARCHAR(30) NOT NULL CHECK (ESTADO IN ('Pendiente', 'Aceptada', 'Rechazada')),
    FECHA_SOLICITUD DATETIME DEFAULT GETDATE(), -- Fecha de la solicitud
    CONSTRAINT PK_SOLICITUD_AMISTAD PRIMARY KEY CLUSTERED (ID_SOLICITUD ASC),
    CONSTRAINT FK_SOLICITUD_SOLICITANTE FOREIGN KEY (ID_USUARIO_SOLICITANTE) REFERENCES USUARIO(ID_USUARIO),
    CONSTRAINT FK_SOLICITUD_DESTINATARIO FOREIGN KEY (ID_USUARIO_DESTINATARIO) REFERENCES USUARIO(ID_USUARIO)
) ON [PRIMARY];
GO

-- Tabla de Calendario (Eventos y Recordatorios)
CREATE TABLE CALENDARIO (
    ID_CALENDARIO BIGINT IDENTITY(1,1) NOT NULL,
    ID_USUARIO BIGINT NOT NULL, -- Paciente
    DIA NVARCHAR(50) NOT NULL,
    FECHA SMALLDATETIME NOT NULL,
    DESCRIPCION NVARCHAR(MAX) NOT NULL,
    TIPO NVARCHAR(30) NOT NULL,
    CONSTRAINT PK_CALENDARIO PRIMARY KEY CLUSTERED (ID_CALENDARIO ASC),
    CONSTRAINT FK_CALENDARIO_PACIENTE FOREIGN KEY (ID_USUARIO) REFERENCES USUARIO(ID_USUARIO)
) ON [PRIMARY]
GO

-- Tabla de Historial de Alarmas
CREATE TABLE HISTORIAL (
    ID_HISTORIAL BIGINT IDENTITY(1,1) NOT NULL,
    ID_CALENDARIO BIGINT NOT NULL,
    FECHA_REGISTRO DATETIME DEFAULT GETDATE(),
    ESTADO NVARCHAR(30) NOT NULL CHECK (ESTADO IN ('Generada', 'Confirmada', 'Ignorada')),
    CONSTRAINT PK_HISTORIAL PRIMARY KEY CLUSTERED (ID_HISTORIAL ASC),
    CONSTRAINT FK_HISTORIAL_CALENDARIO FOREIGN KEY (ID_CALENDARIO) REFERENCES CALENDARIO(ID_CALENDARIO)
) ON [PRIMARY]
GO

-- Tabla de Alertas para Encargados
CREATE TABLE ALERTA (
    ID_ALERTA BIGINT IDENTITY(1,1) NOT NULL,
    ID_HISTORIAL BIGINT NOT NULL,
    ID_ENCARGADO BIGINT NOT NULL,
    ESTADO NVARCHAR(30) NOT NULL CHECK (ESTADO IN ('Pendiente', 'Vista')),
    CONSTRAINT PK_ALERTA PRIMARY KEY CLUSTERED (ID_ALERTA ASC),
    CONSTRAINT FK_ALERTA_HISTORIAL FOREIGN KEY (ID_HISTORIAL) REFERENCES HISTORIAL(ID_HISTORIAL),
    CONSTRAINT FK_ALERTA_ENCARGADO FOREIGN KEY (ID_ENCARGADO) REFERENCES USUARIO(ID_USUARIO)
) ON [PRIMARY]
GO

CREATE TRIGGER trg_ValidarTiposDeUsuarios
ON SOLICITUD_cuidador
FOR INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Variables para almacenar los tipos de usuario
    DECLARE @TipoSolicitante NVARCHAR(35), @TipoDestinatario NVARCHAR(35);

    -- Obtener los tipos de los usuarios involucrados en la solicitud
    SELECT 
        @TipoSolicitante = (SELECT TIPO FROM USUARIO WHERE ID_USUARIO = (SELECT ID_USUARIO_SOLICITANTE FROM INSERTED)),
        @TipoDestinatario = (SELECT TIPO FROM USUARIO WHERE ID_USUARIO = (SELECT ID_USUARIO_DESTINATARIO FROM INSERTED));

    -- Validar que los usuarios sean de tipos diferentes
    IF @TipoSolicitante = @TipoDestinatario
    BEGIN
        RAISERROR('Los usuarios solicitante y destinatario deben ser de tipos diferentes.', 16, 1);
        ROLLBACK;  -- Revertir la transacción si la validación falla
    END
END;
GO

CREATE PROCEDURE sp_IniciarSesion
    @CorreoElectronico NVARCHAR(50),
    @Password NVARCHAR(MAX),
    @DIRECCION_IP VARCHAR(45), -- Nueva variable para la IP del dispositivo
    @NombreDispositivo NVARCHAR(255), -- Nueva variable para el nombre del dispositivo
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT,
    @ref_usuarioId BIGINT OUTPUT, -- Para devolver el ID del usuario
    @ref_usuariotipo NVARCHAR(255) OUTPUT -- Nuevo parámetro para el tipo de usuario
AS
BEGIN
    SET NOCOUNT ON;

    -- Inicializamos valores de salida
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    SET @ref_usuarioId = 0; -- Inicializamos la salida del ID de usuario
    SET @ref_usuariotipo = NULL; -- Inicializamos la salida del tipo de usuario

    BEGIN TRY
        -- Verificar si el usuario existe
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE CORREO_ELECTRONICO = @CorreoElectronico)
        BEGIN
            SET @ref_errorIdBD = 1; -- Error: Usuario no existe
            SET @ref_errorMsgBD = 'El usuario con ese correo electrónico no existe.';
            RETURN;
        END

        -- Validar contraseña y obtener el ID del usuario y su tipo
        SELECT @ref_usuarioId = ID_USUARIO, @ref_usuariotipo = TIPO
        FROM USUARIO
        WHERE CORREO_ELECTRONICO = @CorreoElectronico AND PASSWORD = @Password;

        -- Si no encontró el usuario con la contraseña dada
        IF @ref_usuarioId IS NULL
        BEGIN
            SET @ref_errorIdBD = 2; -- Error: Contraseña incorrecta
            SET @ref_errorMsgBD = 'La contraseña es incorrecta.';
            RETURN;
        END

        -- Registrar el dispositivo (IP y Nombre del dispositivo)
        -- Verificar si el dispositivo ya está registrado para este usuario
        DECLARE @CantidadDispositivos INT;

        -- Contar los dispositivos activos del usuario
        SELECT @CantidadDispositivos = COUNT(*)
        FROM DISPOSITIVOS
        WHERE ID_USUARIO = @ref_usuarioId AND ACTIVO = 1;

        -- Si ya tiene 3 dispositivos activos, desactivar el más antiguo
        IF @CantidadDispositivos >= 3
        BEGIN
            UPDATE DISPOSITIVOS
            SET ACTIVO = 0
            WHERE ID_DISPOSITIVO = (
                SELECT TOP 1 ID_DISPOSITIVO 
                FROM DISPOSITIVOS
                WHERE ID_USUARIO = @ref_usuarioId AND ACTIVO = 1
                ORDER BY ID_DISPOSITIVO ASC
            );
        END

        -- Registrar el nuevo dispositivo con la IP y el nombre del dispositivo
        INSERT INTO DISPOSITIVOS (DIRECCION_IP, NOMBRE_DISPOSITIVO, ID_USUARIO, ACTIVO)
        VALUES (@DIRECCION_IP, @NombreDispositivo, @ref_usuarioId, 1);

        -- Si todo está bien
        SET @ref_errorIdBD = 0; -- Éxito
        SET @ref_errorMsgBD = 'Inicio de sesión y registro del dispositivo exitoso.';

    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER(); -- Error inesperado
        SET @ref_errorMsgBD = ERROR_MESSAGE(); -- Descripción del error
        RETURN;
    END CATCH
END;
GO

CREATE PROCEDURE sp_VerificarIP
    @DireccionIP VARCHAR(45),
    @ref_usuarioId BIGINT OUTPUT,
    @ref_usuariotipo NVARCHAR(255) OUTPUT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    SET @ref_usuarioId = NULL;
    SET @ref_usuariotipo = NULL;
    
    BEGIN TRY
        -- Verify if IP is associated with a user
        SELECT 
            @ref_usuarioId = d.ID_USUARIO,
            @ref_usuariotipo = u.TIPO
        FROM DISPOSITIVOS d
        JOIN USUARIO u ON d.ID_USUARIO = u.ID_USUARIO
        WHERE d.DIRECCION_IP = @DireccionIP
          AND d.ACTIVO = 1;
        
        -- If no match found
        IF @ref_usuarioId IS NULL
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'La IP no está asociada a un usuario o el dispositivo no está activo.';
            RETURN;
        END
        
        -- Update last login date
        UPDATE DISPOSITIVOS
        SET [ULTIMA_VEZ] = CAST(GETDATE() AS smalldatetime)
        WHERE DIRECCION_IP = @DireccionIP
          AND ID_USUARIO = @ref_usuarioId;
        
        SET @ref_errorMsgBD = 'IP verificada exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

go
CREATE PROCEDURE SP_ObtenerTipoUsuario
    @ID_USUARIO BIGINT,
    @TIPO NVARCHAR(35) OUTPUT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    SET @TIPO = NULL;
    
    BEGIN TRY
        -- Verify user exists
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_USUARIO)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El usuario no existe.';
            RETURN;
        END
        
        -- Get user type
        SELECT @TIPO = TIPO
        FROM USUARIO
        WHERE ID_USUARIO = @ID_USUARIO;
        
        SET @ref_errorMsgBD = 'Tipo de usuario obtenido exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO


-- Procedimiento para registrar un usuario
CREATE PROCEDURE SP_RegistrarUsuario
    @NOMBRE NVARCHAR(50),
    @APELLIDO1 NVARCHAR(50),
    @APELLIDO2 NVARCHAR(50),
    @CORREO_ELECTRONICO NVARCHAR(50),
    @USUARIO NVARCHAR(50),
    @PASSWORD NVARCHAR(MAX),
    @FECHA_NACIMIENTO SMALLDATETIME,
    @TIPO NVARCHAR(35),
    @UBICACION NVARCHAR(MAX),
    @ref_idBD BIGINT OUTPUT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Inicializamos valores de salida
    SET @ref_idBD = 0;
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verificar si el usuario o correo electrónico ya existen
        IF EXISTS (SELECT 1 FROM USUARIO WHERE CORREO_ELECTRONICO = @CORREO_ELECTRONICO)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El correo electrónico ya está registrado.';
            RETURN;
        END
        
        IF EXISTS (SELECT 1 FROM USUARIO WHERE USUARIO = @USUARIO)
        BEGIN
            SET @ref_errorIdBD = 2;
            SET @ref_errorMsgBD = 'El nombre de usuario ya está registrado.';
            RETURN;
        END
        
        -- Insertar usuario sin imagen
        INSERT INTO USUARIO (NOMBRE, APELLIDO1, APELLIDO2, CORREO_ELECTRONICO, USUARIO, PASSWORD, FECHA_NACIMIENTO, TIPO, UBICACION)
        VALUES (@NOMBRE, @APELLIDO1, @APELLIDO2, @CORREO_ELECTRONICO, @USUARIO, @PASSWORD, @FECHA_NACIMIENTO, @TIPO, @UBICACION);
        
        -- Obtener el ID del usuario recién insertado
        SET @ref_idBD = SCOPE_IDENTITY();
        SET @ref_errorMsgBD = 'Registro exitoso';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;

GO
-- Procedimiento para generar una solicitud de cuidador
CREATE PROCEDURE SP_GenerarSolicitudCuidador
    @ID_USUARIO_SOLICITANTE BIGINT,
    @USUARIO_DESTINATARIO NVARCHAR(50),
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Inicializamos valores de salida
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        DECLARE @ID_USUARIO_DESTINATARIO BIGINT;

        -- Obtener el ID del destinatario a partir del nombre de usuario
        SELECT @ID_USUARIO_DESTINATARIO = ID_USUARIO FROM USUARIO WHERE USUARIO = @USUARIO_DESTINATARIO;

        -- Verificar que el destinatario exista
        IF @ID_USUARIO_DESTINATARIO IS NULL
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El usuario destinatario no existe.';
            RETURN;
        END

        -- Insertar la solicitud
        INSERT INTO SOLICITUD_CUIDADOR (ID_USUARIO_SOLICITANTE, ID_USUARIO_DESTINATARIO, ESTADO)
        VALUES (@ID_USUARIO_SOLICITANTE, @ID_USUARIO_DESTINATARIO, 'Pendiente');
        
        SET @ref_errorMsgBD = 'Solicitud de cuidador generada exitosamente.';
    END TRY
    BEGIN CATCH
        -- Capturar el error y devolver el código de error y el mensaje
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

-- Procedimiento para aceptar solicitud y ligar en ENCARGADO_PACIENTE
CREATE PROCEDURE SP_CambiarEstadoSolicitudCuidador
    @ID_SOLICITUD BIGINT,
    @ESTADO NVARCHAR(20),
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    DECLARE @ID_USUARIO_SOLICITANTE BIGINT, @ID_USUARIO_DESTINATARIO BIGINT;
    
    BEGIN TRY
        -- Verify if solicitud exists
        IF NOT EXISTS (SELECT 1 FROM SOLICITUD_CUIDADOR WHERE ID_SOLICITUD = @ID_SOLICITUD)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'La solicitud no existe.';
            RETURN;
        END
        
        -- Verify if estado is valid
        IF @ESTADO NOT IN ('Confirmada', 'Rechazada')
        BEGIN
            SET @ref_errorIdBD = 2;
            SET @ref_errorMsgBD = 'Estado no válido. Solo se permite "Confirmada" o "Rechazada".';
            RETURN;
        END
        
        -- Get IDs from solicitante and destinatario
        SELECT @ID_USUARIO_SOLICITANTE = ID_USUARIO_SOLICITANTE, 
               @ID_USUARIO_DESTINATARIO = ID_USUARIO_DESTINATARIO
        FROM SOLICITUD_CUIDADOR 
        WHERE ID_SOLICITUD = @ID_SOLICITUD;
        
        -- Change solicitud status
        UPDATE SOLICITUD_CUIDADOR 
        SET ESTADO = @ESTADO 
        WHERE ID_SOLICITUD = @ID_SOLICITUD;
        
        -- Register in SOLICITUD_cuidador (this seems redundant in the original SP, might be a duplication)
        INSERT INTO SOLICITUD_cuidador (ID_USUARIO_SOLICITANTE, ID_USUARIO_DESTINATARIO, ESTADO)
        VALUES (@ID_USUARIO_SOLICITANTE, @ID_USUARIO_DESTINATARIO, @ESTADO);
        
        SET @ref_errorMsgBD = 'Estado de solicitud cambiado exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

CREATE PROCEDURE EliminarSolicitud
    @ID_SOLICITUD BIGINT,
    @ID_USUARIO_ENCARGADO BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if solicitud exists
        IF NOT EXISTS (SELECT 1 FROM SOLICITUD_cuidador WHERE ID_SOLICITUD = @ID_SOLICITUD)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'La solicitud no existe.';
            RETURN;
        END
        
        -- Verify if user is authorized to delete
        IF NOT EXISTS (
            SELECT 1
            FROM SOLICITUD_cuidador s
            WHERE s.ID_SOLICITUD = @ID_SOLICITUD
            AND s.ID_USUARIO_SOLICITANTE = @ID_USUARIO_ENCARGADO
        )
        BEGIN
            SET @ref_errorIdBD = 2;
            SET @ref_errorMsgBD = 'Solo el encargado puede eliminar esta solicitud.';
            RETURN;
        END
        
        -- Delete solicitud
        DELETE FROM SOLICITUD_cuidador WHERE ID_SOLICITUD = @ID_SOLICITUD;
        
        SET @ref_errorMsgBD = 'Solicitud eliminada exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

CREATE PROCEDURE SP_ListarDispositivosPorUsuario
    @ID_USUARIO BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- Seleccionar los dispositivos registrados del usuario específico
    SELECT 
        ID_DISPOSITIVO,
        DIRECCION_IP,
		NOMBRE_DISPOSITIVO,
        ACTIVO,
		ULTIMA_VEZ
    FROM DISPOSITIVOS
    WHERE ID_USUARIO = @ID_USUARIO
    ORDER BY ID_DISPOSITIVO;
END;
GO


CREATE PROCEDURE CrearAlertaAlPaciente
    @ID_USUARIO_ENCARGADO BIGINT,
    @ID_USUARIO_PACIENTE BIGINT,
    @DESCRIPCION NVARCHAR(MAX),
    @TIPO NVARCHAR(30),
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if users exist
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_USUARIO_ENCARGADO)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El encargado no existe.';
            RETURN;
        END
        
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_USUARIO_PACIENTE)
        BEGIN
            SET @ref_errorIdBD = 2;
            SET @ref_errorMsgBD = 'El paciente no existe.';
            RETURN;
        END
        
        -- Verify relationship between encargado and paciente
        IF NOT EXISTS (
            SELECT 1 
            FROM SOLICITUD_cuidador s
            WHERE s.ID_USUARIO_SOLICITANTE = @ID_USUARIO_ENCARGADO
            AND s.ID_USUARIO_DESTINATARIO = @ID_USUARIO_PACIENTE
            AND s.ESTADO = 'Aceptada'
        )
        BEGIN
            SET @ref_errorIdBD = 3;
            SET @ref_errorMsgBD = 'El encargado no tiene una solicitud aceptada para este paciente.';
            RETURN;
        END
        
        -- Create calendar event
        DECLARE @ID_CALENDARIO BIGINT;
        INSERT INTO CALENDARIO (ID_USUARIO, DIA, FECHA, DESCRIPCION, TIPO)
        VALUES (@ID_USUARIO_PACIENTE, 'Evento', GETDATE(), @DESCRIPCION, @TIPO);
        
        SET @ID_CALENDARIO = SCOPE_IDENTITY();
        
        -- Create alert history
        INSERT INTO HISTORIAL (ID_CALENDARIO, ESTADO)
        VALUES (@ID_CALENDARIO, 'Generada');
        
        DECLARE @ID_HISTORIAL BIGINT = SCOPE_IDENTITY();
        
        -- Create alert for encargado
        INSERT INTO ALERTA (ID_HISTORIAL, ID_ENCARGADO, ESTADO)
        VALUES (@ID_HISTORIAL, @ID_USUARIO_ENCARGADO, 'Pendiente');
        
        SET @ref_errorMsgBD = 'Alerta creada exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

CREATE PROCEDURE SP_VisualizarSolicitudes
    @ID_USUARIO BIGINT
AS
BEGIN
    SELECT 
        SC.ID_SOLICITUD,
        USOLICITANTE.NOMBRE + ' ' + USOLICITANTE.APELLIDO1 + ' ' + ISNULL(USOLICITANTE.APELLIDO2, '') AS SOLICITANTE,
        UDESTINATARIO.NOMBRE + ' ' + UDESTINATARIO.APELLIDO1 + ' ' + ISNULL(UDESTINATARIO.APELLIDO2, '') AS DESTINATARIO,
        SC.ESTADO
    FROM SOLICITUD_CUIDADOR SC
    INNER JOIN USUARIO USOLICITANTE ON SC.ID_USUARIO_SOLICITANTE = USOLICITANTE.ID_USUARIO
    INNER JOIN USUARIO UDESTINATARIO ON SC.ID_USUARIO_DESTINATARIO = UDESTINATARIO.ID_USUARIO
    WHERE SC.ID_USUARIO_SOLICITANTE = @ID_USUARIO OR SC.ID_USUARIO_DESTINATARIO = @ID_USUARIO;
END;
GO
-- EDITAR INFORMACIÓN DE UN USUARIO
CREATE PROCEDURE SP_EditarUsuario
    @ID_USUARIO BIGINT,
    @NOMBRE NVARCHAR(50),
    @APELLIDO1 NVARCHAR(50),
    @APELLIDO2 NVARCHAR(50),
    @CORREO_ELECTRONICO NVARCHAR(50),
    @USUARIO NVARCHAR(50),
    @FECHA_NACIMIENTO SMALLDATETIME,
    @UBICACION NVARCHAR(MAX),
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Inicializar valores de salida
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verificar si el usuario existe
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_USUARIO)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El usuario no existe.';
            RETURN;
        END
        
        -- Verificar si el correo ya está en uso por otro usuario
        IF EXISTS (SELECT 1 FROM USUARIO WHERE CORREO_ELECTRONICO = @CORREO_ELECTRONICO AND ID_USUARIO != @ID_USUARIO)
        BEGIN
            SET @ref_errorIdBD = 2;
            SET @ref_errorMsgBD = 'El correo electrónico ya está en uso por otro usuario.';
            RETURN;
        END
        
        -- Verificar si el nombre de usuario ya está en uso por otro usuario
        IF EXISTS (SELECT 1 FROM USUARIO WHERE USUARIO = @USUARIO AND ID_USUARIO != @ID_USUARIO)
        BEGIN
            SET @ref_errorIdBD = 3;
            SET @ref_errorMsgBD = 'El nombre de usuario ya está en uso por otro usuario.';
            RETURN;
        END
        
        -- Actualizar la información del usuario
        UPDATE USUARIO
        SET NOMBRE = @NOMBRE,
            APELLIDO1 = @APELLIDO1,
            APELLIDO2 = @APELLIDO2,
            CORREO_ELECTRONICO = @CORREO_ELECTRONICO,
            USUARIO = @USUARIO,
            FECHA_NACIMIENTO = @FECHA_NACIMIENTO,
            UBICACION = @UBICACION
        WHERE ID_USUARIO = @ID_USUARIO;
        
        SET @ref_errorMsgBD = 'Usuario actualizado exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO


CREATE PROCEDURE SP_CrearAlertaPaciente
    @ID_USUARIO BIGINT, -- ID del paciente
    @DIA NVARCHAR(50), -- Día de la semana
    @FECHA SMALLDATETIME,
    @DESCRIPCION NVARCHAR(MAX),
    @TIPO NVARCHAR(30),
    @ref_idAlerta BIGINT OUTPUT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Inicializar valores de salida
    SET @ref_idAlerta = 0;
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    -- Variables para el proceso
    DECLARE @ID_CALENDARIO BIGINT;
    DECLARE @ID_HISTORIAL BIGINT;
    DECLARE @TIPO_USUARIO NVARCHAR(35);
    
    BEGIN TRY
        -- Verificar si el usuario es un paciente
        SELECT @TIPO_USUARIO = TIPO FROM USUARIO WHERE ID_USUARIO = @ID_USUARIO;
        
        IF @TIPO_USUARIO != 'Paciente'
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'Solo los pacientes pueden crear alertas.';
            RETURN;
        END
        
        -- Crear el evento en el calendario
        INSERT INTO CALENDARIO (ID_USUARIO, DIA, FECHA, DESCRIPCION, TIPO)
        VALUES (@ID_USUARIO, @DIA, @FECHA, @DESCRIPCION, @TIPO);
        SET @ID_CALENDARIO = SCOPE_IDENTITY();
        
        -- Crear el historial de la alerta como "Generada"
        INSERT INTO HISTORIAL (ID_CALENDARIO, ESTADO)
        VALUES (@ID_CALENDARIO, 'Generada');
        SET @ID_HISTORIAL = SCOPE_IDENTITY();
        
        -- Crear alertas para todos los encargados del paciente
        INSERT INTO ALERTA (ID_HISTORIAL, ID_ENCARGADO, ESTADO)
        SELECT @ID_HISTORIAL, ID_USUARIO_SOLICITANTE, 'Pendiente'
        FROM SOLICITUD_cuidador
        WHERE ID_USUARIO_DESTINATARIO = @ID_USUARIO
        AND ESTADO = 'Aceptada';
        
        SET @ref_idAlerta = @ID_HISTORIAL;
        SET @ref_errorMsgBD = 'Alerta creada exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;

GO

-- MARCAR ALERTA COMO VISTA (DESPUÉS DE 15 MIN SE MARCA COMO NO VISTA)
CREATE PROCEDURE SP_MarcarAlertaVista
    @ID_ALERTA BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Inicializar valores de salida
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verificar si la alerta existe
        IF NOT EXISTS (SELECT 1 FROM ALERTA WHERE ID_ALERTA = @ID_ALERTA)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'La alerta no existe.';
            RETURN;
        END
        
        -- Verificar si ya pasaron 15 minutos desde la creación
        DECLARE @FECHA_CREACION DATETIME;
        DECLARE @ID_HISTORIAL BIGINT;
        
        SELECT @ID_HISTORIAL = ID_HISTORIAL FROM ALERTA WHERE ID_ALERTA = @ID_ALERTA;
        SELECT @FECHA_CREACION = FECHA_REGISTRO FROM HISTORIAL WHERE ID_HISTORIAL = @ID_HISTORIAL;
        
        IF DATEDIFF(MINUTE, @FECHA_CREACION, GETDATE()) > 15
        BEGIN
            -- Si pasaron más de 15 minutos, marcar como "Ignorada"
            UPDATE HISTORIAL
            SET ESTADO = 'Ignorada'
            WHERE ID_HISTORIAL = @ID_HISTORIAL;
            
            UPDATE ALERTA
            SET ESTADO = 'Vista'
            WHERE ID_ALERTA = @ID_ALERTA;
            
            SET @ref_errorMsgBD = 'Alerta marcada como ignorada por pasar más de 15 minutos.';
        END
        ELSE
        BEGIN
            -- Si no pasaron 15 minutos, marcar como "Confirmada"
            UPDATE HISTORIAL
            SET ESTADO = 'Confirmada'
            WHERE ID_HISTORIAL = @ID_HISTORIAL;
            
            UPDATE ALERTA
            SET ESTADO = 'Vista'
            WHERE ID_ALERTA = @ID_ALERTA;
            
            SET @ref_errorMsgBD = 'Alerta marcada como confirmada.';
        END
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

-- VER ALERTAS DEL PACIENTE
CREATE PROCEDURE VisualizarAlertasEncargado
    @ID_ENCARGADO BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify user exists and is an "Encargado"
        DECLARE @TipoUsuario NVARCHAR(35);
        SELECT @TipoUsuario = TIPO FROM USUARIO WHERE ID_USUARIO = @ID_ENCARGADO;
        
        IF @TipoUsuario IS NULL
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El usuario no existe.';
            RETURN;
        END
        
        IF @TipoUsuario != 'Encargado'
        BEGIN
            SET @ref_errorIdBD = 2;
            SET @ref_errorMsgBD = 'El usuario no es un encargado.';
            RETURN;
        END
        
        -- Select alerts
        SELECT a.ID_ALERTA, h.FECHA_REGISTRO, h.ESTADO AS EstadoHistorial, a.ESTADO AS EstadoAlerta, c.DESCRIPCION
        FROM ALERTA a
        JOIN HISTORIAL h ON a.ID_HISTORIAL = h.ID_HISTORIAL
        JOIN CALENDARIO c ON h.ID_CALENDARIO = c.ID_CALENDARIO
        WHERE a.ID_ENCARGADO = @ID_ENCARGADO;
        
        SET @ref_errorMsgBD = 'Alertas visualizadas exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO
CREATE PROCEDURE SP_VerAlertasPaciente
    @ID_PACIENTE BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if paciente exists
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_PACIENTE AND TIPO = 'Paciente')
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El paciente no existe.';
            RETURN;
        END
        
        -- Select alertas
        SELECT 
            h.ID_HISTORIAL,
            c.ID_CALENDARIO,
            c.DIA,
            c.FECHA,
            c.DESCRIPCION,
            c.TIPO,
            h.ESTADO AS EstadoHistorial,
            h.FECHA_REGISTRO
        FROM HISTORIAL h
        INNER JOIN CALENDARIO c ON h.ID_CALENDARIO = c.ID_CALENDARIO
        WHERE c.ID_USUARIO = @ID_PACIENTE
        ORDER BY h.FECHA_REGISTRO DESC;
        
        SET @ref_errorMsgBD = 'Alertas obtenidas exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

CREATE PROCEDURE SP_VerAlertasEncargado
    @ID_ENCARGADO BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if encargado exists
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_ENCARGADO AND TIPO = 'Encargado')
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El encargado no existe.';
            RETURN;
        END
        
        -- Select alertas
        SELECT 
            a.ID_ALERTA,
            h.ID_HISTORIAL,
            c.ID_CALENDARIO,
            u.NOMBRE + ' ' + u.APELLIDO1 AS NombrePaciente,
            c.DIA,
            c.FECHA,
            c.DESCRIPCION,
            c.TIPO,
            h.ESTADO AS EstadoHistorial,
            a.ESTADO AS EstadoAlerta,
            h.FECHA_REGISTRO
        FROM ALERTA a
        INNER JOIN HISTORIAL h ON a.ID_HISTORIAL = h.ID_HISTORIAL
        INNER JOIN CALENDARIO c ON h.ID_CALENDARIO = c.ID_CALENDARIO
        INNER JOIN USUARIO u ON c.ID_USUARIO = u.ID_USUARIO
        WHERE a.ID_ENCARGADO = @ID_ENCARGADO
        ORDER BY h.FECHA_REGISTRO DESC;
        
        SET @ref_errorMsgBD = 'Alertas obtenidas exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO
CREATE PROCEDURE SP_EliminarAlerta
    @ID_Alerta BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if alerta exists
        IF NOT EXISTS (SELECT 1 FROM ALERTA WHERE ID_ALERTA = @ID_Alerta)
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'La alerta no existe.';
            RETURN;
        END
        
        BEGIN TRANSACTION;
        
        -- Identify the historial record associated with the alert
        DECLARE @ID_Historial BIGINT;
        SELECT @ID_Historial = ID_HISTORIAL FROM ALERTA WHERE ID_ALERTA = @ID_Alerta;
        
        -- Delete the alert
        DELETE FROM ALERTA WHERE ID_ALERTA = @ID_Alerta;
        
        -- Delete the associated history record
        DELETE FROM HISTORIAL WHERE ID_HISTORIAL = @ID_Historial;
        
        COMMIT TRANSACTION;
        
        SET @ref_errorMsgBD = 'Alerta eliminada correctamente.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
            
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO


CREATE PROCEDURE SP_VerHistorialAlertasPaciente
    @ID_Paciente BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if paciente exists
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_Paciente AND TIPO = 'Paciente')
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El paciente no existe.';
            RETURN;
        END
        
        -- Select historial
        SELECT 
            h.ID_HISTORIAL,
            c.DESCRIPCION AS Descripcion_Evento,
            c.TIPO AS Tipo_Evento,
            c.FECHA AS Fecha_Evento,
            h.FECHA_REGISTRO AS Fecha_Registro,
            h.ESTADO AS Estado_Alerta
        FROM HISTORIAL h
        INNER JOIN CALENDARIO c ON h.ID_CALENDARIO = c.ID_CALENDARIO
        WHERE c.ID_USUARIO = @ID_Paciente
        ORDER BY h.FECHA_REGISTRO DESC;
        
        SET @ref_errorMsgBD = 'Historial de alertas obtenido exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO

-- SP_VerHistorialAlertasEncargado with error handling
CREATE PROCEDURE SP_VerHistorialAlertasEncargado
    @ID_Encargado BIGINT,
    @ref_errorIdBD INT OUTPUT,
    @ref_errorMsgBD NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Initialize output parameters
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;
    
    BEGIN TRY
        -- Verify if encargado exists
        IF NOT EXISTS (SELECT 1 FROM USUARIO WHERE ID_USUARIO = @ID_Encargado AND TIPO = 'Encargado')
        BEGIN
            SET @ref_errorIdBD = 1;
            SET @ref_errorMsgBD = 'El encargado no existe.';
            RETURN;
        END
        
        -- Select historial
        SELECT 
            a.ID_ALERTA,
            h.ID_HISTORIAL,
            u.NOMBRE + ' ' + u.APELLIDO1 AS Nombre_Paciente,
            c.DESCRIPCION AS Descripcion_Evento,
            c.TIPO AS Tipo_Evento,
            c.FECHA AS Fecha_Evento,
            h.FECHA_REGISTRO AS Fecha_Registro,
            h.ESTADO AS Estado_Historial,
            a.ESTADO AS Estado_Alerta
        FROM ALERTA a
        INNER JOIN HISTORIAL h ON a.ID_HISTORIAL = h.ID_HISTORIAL
        INNER JOIN CALENDARIO c ON h.ID_CALENDARIO = c.ID_CALENDARIO
        INNER JOIN USUARIO u ON c.ID_USUARIO = u.ID_USUARIO
        WHERE a.ID_ENCARGADO = @ID_Encargado
        ORDER BY h.FECHA_REGISTRO DESC;
        
        SET @ref_errorMsgBD = 'Historial de alertas obtenido exitosamente.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER();
        SET @ref_errorMsgBD = ERROR_MESSAGE();
    END CATCH
END;
GO
CREATE PROCEDURE sp_CerrarSesion
    @DireccionIP VARCHAR(45), -- Dirección IP del dispositivo que se desea eliminar
    @ref_errorIdBD INT OUTPUT, -- Parámetro de salida para el ID del error
    @ref_errorMsgBD NVARCHAR(255) OUTPUT -- Mensaje de error o éxito
AS
BEGIN
    SET NOCOUNT ON;

    -- Inicializamos los valores de salida
    SET @ref_errorIdBD = 0;
    SET @ref_errorMsgBD = NULL;

    BEGIN TRY
        -- Verificar si el dispositivo con esa IP existe en la base de datos
        IF NOT EXISTS (SELECT 1 FROM DISPOSITIVOS WHERE DIRECCION_IP = @DireccionIP)
        BEGIN
            SET @ref_errorIdBD = 1; -- Error: Dispositivo no encontrado
            SET @ref_errorMsgBD = 'El dispositivo con esa dirección IP no se encuentra registrado.';
            RETURN;
        END

        -- Eliminar el dispositivo asociado a esa IP
        DELETE FROM DISPOSITIVOS
        WHERE DIRECCION_IP = @DireccionIP;

        SET @ref_errorIdBD = 0; -- Éxito
        SET @ref_errorMsgBD = 'Cierre de sesión exitoso. Dispositivo eliminado.';
    END TRY
    BEGIN CATCH
        SET @ref_errorIdBD = ERROR_NUMBER(); -- Error inesperado
        SET @ref_errorMsgBD = ERROR_MESSAGE(); -- Descripción del error
    END CATCH
END;
GO